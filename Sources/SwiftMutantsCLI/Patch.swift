// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsReport

/// One mutant, as a change somebody can apply.
///
/// `explain` says what a survivor is. The next question is always the same - "would a test
/// actually catch this if I wrote one?" - and the only way to answer it is to make the
/// change and run under a debugger. Doing that by hand means finding the byte span, editing
/// it, remembering to put it back, and being sure it was the right span in the first place.
///
/// A unified diff is that, and three other things besides: readable before it is applied,
/// applied by `git apply`, reverted by `git apply -R`, and refused by both if the file has
/// moved on since the run.
enum Patch {

    /// How many unchanged lines to carry on each side.
    ///
    /// Three, which is what every diff tool defaults to. Without context a patch applies to
    /// whatever happens to be at that line number, which is how a patch quietly edits the
    /// wrong thing.
    static let context = 3

    /// The patch for one mutant, or nothing if the file is not what it was.
    ///
    /// The span has to still hold exactly what the mutant says it replaced. Anything else
    /// is a file that has moved on, and the honest answer is nothing rather than a diff
    /// against a guess - a patch that applies where it does not belong is worse than no
    /// patch at all.
    static func of(_ mutant: RunReport.Mutant, in source: String) -> String? {
        let bytes = Array(source.utf8)
        let span = mutant.span
        guard span.start >= 0, span.end <= bytes.count, span.start <= span.end,
            String(decoding: bytes[span.start..<span.end], as: UTF8.self) == mutant.original
        else {
            return nil
        }

        let mutated =
            String(decoding: bytes[0..<span.start], as: UTF8.self) + mutant.replacement
            + String(decoding: bytes[span.end...], as: UTF8.self)
        return Self.diff(source, mutated, path: mutant.path)
    }

    /// A unified diff of two whole files.
    ///
    /// One hunk, because a mutant is one edit. The lines before the first difference and
    /// after the last are the context; everything between them is replaced wholesale, which
    /// is both correct and the smallest thing worth reading for an edit this size.
    static func diff(_ before: String, _ after: String, path: String) -> String? {
        let old = Self.lines(of: before)
        let new = Self.lines(of: after)

        var first = 0
        while first < old.count, first < new.count, old[first] == new[first] { first += 1 }
        guard first < old.count || first < new.count else { return nil }

        var back = 0
        while back < old.count - first, back < new.count - first,
            old[old.count - 1 - back] == new[new.count - 1 - back]
        {
            back += 1
        }

        let start = max(0, first - Self.context)
        let oldEnd = min(old.count, old.count - back + Self.context)
        let newEnd = min(new.count, new.count - back + Self.context)

        var body = old[start..<first].map { " \($0)" }
        body += old[first..<(old.count - back)].map { "-\($0)" }
        body += new[first..<(new.count - back)].map { "+\($0)" }
        body += old[(old.count - back)..<oldEnd].map { " \($0)" }

        return """
            --- a/\(path)
            +++ b/\(path)
            @@ -\(start + 1),\(oldEnd - start) +\(start + 1),\(newEnd - start) @@
            \(body.joined(separator: "\n"))

            """
    }

    /// A file's lines, without the trailing empty one a final newline produces.
    static func lines(of source: String) -> [String] {
        var found = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if found.last?.isEmpty == true { found.removeLast() }
        return found
    }
}
