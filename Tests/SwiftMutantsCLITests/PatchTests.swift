// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsReport
import Testing

@testable import SwiftMutantsCLI

/// One mutant, as a change somebody can apply.
///
/// `explain` says what a survivor is. The next question is always the same - "would a test
/// actually catch this if I wrote one?" - and the only way to answer it is to make the
/// change and run under a debugger. Doing that by hand means finding the byte span, editing
/// it, remembering to put it back, and being sure it was the right span.
///
/// The patch is that, as a diff: readable before it is applied, applied by `git apply`,
/// reverted by `git apply -R`, and refused by both if the file has moved on.
@Suite("A mutant as a patch")
struct PatchTests {

    static let source = "func f(_ a: Int, _ b: Int) -> Bool {\n    a < b\n}\n"

    static func mutant(
        path: String = "Sources/Codec/Header.swift",
        span: (Int, Int) = (43, 44),
        original: String = "<",
        replacement: String = "<="
    ) -> RunReport.Mutant {
        RunReport.Mutant(
            id: String(repeating: "a", count: 64),
            path: path,
            line: .init(2),
            column: .init(7),
            span: RunReport.Span(start: span.0, end: span.1),
            rule: "lt-to-le@1",
            original: original,
            replacement: replacement,
            outcome: "survived",
            killedBy: [],
            ran: [],
            testsStarted: 0,
            attempts: 1,
            durationMilliseconds: 1
        )
    }

    @Test("says which file it is about, twice, the way a patch does")
    func namesTheFile() throws {
        let patch = try #require(Patch.of(Self.mutant(), in: Self.source))
        #expect(patch.contains("--- a/Sources/Codec/Header.swift"))
        #expect(patch.contains("+++ b/Sources/Codec/Header.swift"))
    }

    @Test("changes the line the mutant is on, and only that line")
    func changesOneLine() throws {
        let patch = try #require(Patch.of(Self.mutant(), in: Self.source))
        #expect(patch.contains("-    a < b"))
        #expect(patch.contains("+    a <= b"))
        #expect(
            patch.split(separator: "\n").count { $0.hasPrefix("-") && !$0.hasPrefix("---") } == 1)
    }

    /// Without context a patch applies to whatever happens to be at that line number, which
    /// is how a patch quietly edits the wrong thing.
    @Test("carries the lines around it, so it can only apply where it belongs")
    func carriesContext() throws {
        let patch = try #require(Patch.of(Self.mutant(), in: Self.source))
        #expect(patch.contains(" func f(_ a: Int, _ b: Int) -> Bool {"))
        #expect(patch.contains(" }"))
    }

    @Test("says where in the file the change is, the way a patch does")
    func hasAHunkHeader() throws {
        let patch = try #require(Patch.of(Self.mutant(), in: Self.source))
        #expect(patch.contains("@@ -1,3 +1,3 @@"))
    }

    /// The one thing a patch must never do is apply somewhere it does not belong. A span
    /// that does not hold what the mutant says it holds is a file that has moved on, and
    /// the honest answer is nothing rather than a diff against a guess.
    @Test("refuses a file that no longer says what the mutant says it said")
    func refusesAMovedFile() {
        #expect(Patch.of(Self.mutant(), in: "something else entirely\n") == nil)
        #expect(Patch.of(Self.mutant(span: (0, 1)), in: Self.source) == nil)
    }

    @Test("refuses a span that is not in the file at all")
    func refusesAnImpossibleSpan() {
        #expect(Patch.of(Self.mutant(span: (9000, 9001)), in: Self.source) == nil)
    }

    /// A patch ends with a newline or `git apply` complains about the last line.
    @Test("ends the way a patch ends")
    func endsProperly() throws {
        #expect(try #require(Patch.of(Self.mutant(), in: Self.source)).hasSuffix("\n"))
    }

    /// A change that removes a line leaves the file shorter, and the header says so - the
    /// two counts in it are what `git apply` checks before it touches anything.
    @Test("holds a change that covers more than one line")
    func acrossLines() throws {
        let source = "let a = [\n    1, 2,\n]\n"
        let mutant = Self.mutant(span: (9, 19), original: "\n    1, 2,", replacement: "")
        let patch = try #require(Patch.of(mutant, in: source))
        #expect(patch.contains("@@ -1,3 +1,2 @@"), "\(patch)")
        #expect(patch.contains("-    1, 2,"))
        #expect(patch.contains(" let a = ["))
        #expect(patch.contains(" ]"))
    }
}
