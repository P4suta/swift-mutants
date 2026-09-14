// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// What a program compiles to, as one number.
///
/// A mutant the compiler turns into the same program as the original cannot be caught by
/// any test, ever. It is not a hole in somebody's suite - it is a mutant that should never
/// have been made, and without this every run reports it as a survivor and costs somebody
/// the afternoon it takes to work out why nothing catches it.
///
/// The compiler already knows. At `-O`, `x * 1` and `x` are the same instruction sequence,
/// measured on this toolchain; `x + 1` is not. This is how it is asked.
///
/// Everything here is about what may be ignored. SIL carries source locations, debug scopes
/// and comments, and every one of them moves when a byte does - so a fingerprint that kept
/// them would say every mutant differs from the original, which is true of the text and
/// false of the program. What is never ignored is the instructions and the values they
/// name, because that is the program.
public enum Fingerprint {

    /// The fingerprint of some SIL.
    public static func of(_ sil: String) -> Digest {
        Digest.of(Self.normalised(sil))
    }

    /// The same SIL with everything that is about the text removed.
    static func normalised(_ sil: String) -> String {
        var kept: [String] = []
        for line in sil.split(separator: "\n", omittingEmptySubsequences: false) {
            // A comment is the compiler talking to a reader, and it names the very
            // identifiers that move when anything is inserted.
            var stripped = String(line)
            if let comment = Self.firstRange(of: "//", in: stripped) {
                stripped = String(stripped[stripped.startIndex..<comment.lowerBound])
            }
            stripped = Self.removingLocations(stripped)
            stripped = Self.removingScopes(stripped)
            stripped = stripped.split(separator: " ").joined(separator: " ")
            guard !stripped.isEmpty else { continue }
            kept.append(stripped)
        }
        return kept.joined(separator: "\n")
    }

    /// The same line without `loc "file":line:column`.
    static func removingLocations(_ line: String) -> String {
        var kept = ""
        var rest = line
        while let start = Self.firstRange(of: "loc \"", in: rest) {
            kept += rest[rest.startIndex..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let quote = after.firstIndex(of: "\"") else { return kept + String(after) }
            var tail = after[after.index(after: quote)...]
            // The `:line:column` that follows.
            while let first = tail.first, first == ":" || first.isNumber {
                tail = tail.dropFirst()
            }
            rest = String(tail)
        }
        return kept + rest
    }

    /// Where a needle first appears, without reaching for Foundation.
    ///
    /// This module is on the pure side of the line: it is given text and gives back a
    /// number, and a module that imported Foundation to find a substring would be a module
    /// that could open a file.
    static func firstRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        let needled = Array(needle)
        guard !needled.isEmpty else { return nil }
        var start = haystack.startIndex
        while start < haystack.endIndex {
            var here = start
            var matched = 0
            while matched < needled.count, here < haystack.endIndex,
                haystack[here] == needled[matched]
            {
                matched += 1
                here = haystack.index(after: here)
            }
            if matched == needled.count { return start..<here }
            start = haystack.index(after: start)
        }
        return nil
    }

    /// The same line without `scope N`, however it is punctuated.
    ///
    /// Scopes are numbered in the order they are emitted, so inserting anything renumbers
    /// all of them - which says nothing at all about what the program does.
    static func removingScopes(_ line: String) -> String {
        guard let start = Self.firstRange(of: "scope ", in: line) else { return line }
        var tail = line[start.upperBound...]
        while let first = tail.first, first.isNumber { tail = tail.dropFirst() }
        let head = line[line.startIndex..<start.lowerBound]
        return Self.removingScopes(String(head.hasSuffix(", ") ? head.dropLast(2) : head) + tail)
    }
}
