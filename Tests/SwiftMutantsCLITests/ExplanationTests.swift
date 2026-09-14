// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsReport
import Testing

@testable import SwiftMutantsCLI

/// One mutant's whole story, for somebody deciding what to do about it.
///
/// A run's summary says a hundred and eighty things survived. That is a number, not a
/// task. The work is one mutant at a time: what was changed, where, which tests ran and
/// did not notice - and whether any test ran at all, which is a different problem with a
/// different fix. `explain` is the command that turns a row in a report into that.
@Suite("Explaining one mutant")
struct ExplanationTests {

    static func mutant(
        id: String = String(repeating: "a", count: 64),
        outcome: String = "survived",
        killedBy: [String] = [],
        testsStarted: Int = 3
    ) -> RunReport.Mutant {
        RunReport.Mutant(
            id: id,
            path: "Sources/Codec/Header.swift",
            line: .init(42),
            column: .init(9),
            span: RunReport.Span(start: 100, end: 101),
            rule: "lt-to-le@1",
            original: "<",
            replacement: "<=",
            outcome: outcome,
            killedBy: killedBy,
            ran: Array(0..<testsStarted),
            testsStarted: testsStarted,
            attempts: 1,
            durationMilliseconds: 231
        )
    }

    static func lines(_ mutant: RunReport.Mutant, tests: [String] = []) -> [String] {
        Explanation.of(mutant, reachedBy: tests)
    }

    @Test("says where it is, in the words an editor takes")
    func saysWhereItIs() {
        let said = Self.lines(Self.mutant()).joined(separator: "\n")
        #expect(said.contains("Sources/Codec/Header.swift:42:9"))
    }

    /// What it did, in the bytes it did it with. A rule name and a line number send a
    /// reader back to a file that may have moved on.
    @Test("says what it changed, and to what")
    func saysWhatItChanged() {
        let said = Self.lines(Self.mutant()).joined(separator: "\n")
        #expect(said.contains("<"))
        #expect(said.contains("<="))
        #expect(said.contains("lt-to-le@1"))
    }

    @Test("names it in full, so it can be looked up again")
    func namesItInFull() {
        let identity = String(repeating: "b", count: 64)
        #expect(Self.lines(Self.mutant(id: identity)).contains { $0.contains(identity) })
    }

    /// The two survivors are different problems. One needs an assertion; the other needs a
    /// test, or a deletion. Saying which is most of the value of the command.
    @Test("says a survivor no test reaches is not the same as one nothing noticed")
    func twoKindsOfSurvivor() {
        let unreached = Self.lines(Self.mutant(testsStarted: 0)).joined(separator: "\n")
        let unnoticed = Self.lines(
            Self.mutant(testsStarted: 3), tests: ["P.S/a()", "P.S/b()", "P.S/c()"]
        ).joined(separator: "\n")

        #expect(unreached.contains("no test"))
        #expect(!unnoticed.contains("no test"))
        #expect(unnoticed.contains("3 tests"))
    }

    /// The tests that ran and did not notice, by name. Those are the ones an assertion
    /// belongs in, and a reader should not have to guess which of four hundred they are.
    @Test("names the tests that looked at it and said nothing")
    func namesTheTestsThatMissedIt() {
        let said = Self.lines(
            Self.mutant(testsStarted: 2), tests: ["P.S/a()", "P.S/b()"]
        ).joined(separator: "\n")
        #expect(said.contains("P.S/a()"))
        #expect(said.contains("P.S/b()"))
    }

    /// A long list is cut, because a mutant reached by four hundred tests is a mutant
    /// whose problem is not the list.
    @Test("cuts a list nobody could read")
    func cutsALongList() {
        let many = (0..<50).map { "P.S/t\($0)()" }
        let said = Self.lines(Self.mutant(testsStarted: 50), tests: many)
        #expect(said.count < 30, "\(said.count) lines")
        #expect(said.joined(separator: "\n").contains("and 30 more"))
    }

    /// A mutant that was caught is a different story, and a short one: this is what caught
    /// it, and there is nothing to do.
    @Test("says what caught a mutant that was caught")
    func saysWhatCaughtIt() {
        let said = Self.lines(
            Self.mutant(outcome: "killed", killedBy: ["P.S/a()"])
        ).joined(separator: "\n")
        #expect(said.contains("killed"))
        #expect(said.contains("P.S/a()"))
        #expect(!said.contains("no test"))
    }

    /// A deadline is a weaker claim than an assertion, and a reader deciding what to do
    /// about one deserves to be told which they have.
    @Test("says what a deadline means, and what it does not")
    func aDeadlineIsNotAnAssertion() {
        let said = Self.lines(Self.mutant(outcome: "timed-out")).joined(separator: "\n")
        #expect(said.contains("ran out of time"))
        #expect(said.contains("detected"))
        #expect(!said.contains("no test"))
    }

    /// A position it never worked out is said plainly rather than printed as `:0:0`, which
    /// an editor would take somewhere wrong.
    @Test("says where it is even when it does not know the line")
    func withoutALine() {
        let mutant = RunReport.Mutant(
            id: String(repeating: "a", count: 64),
            path: "Sources/Codec/Header.swift",
            line: .init(nil),
            column: .init(nil),
            span: RunReport.Span(start: 100, end: 101),
            rule: "lt-to-le@1",
            original: "<",
            replacement: "<=",
            outcome: "survived",
            killedBy: [],
            ran: [],
            testsStarted: 0,
            attempts: 1,
            durationMilliseconds: 231
        )
        let said = Self.lines(mutant).joined(separator: "\n")
        #expect(said.contains("Sources/Codec/Header.swift"))
        #expect(!said.contains(":0:0"))
        #expect(said.contains("bytes 100"))
    }
}

/// Finding the one a person meant.
@Suite("Finding a mutant by what somebody typed")
struct MutantLookupTests {

    static func mutants() -> [RunReport.Mutant] {
        ["ab12", "ab34", "cd56"].map {
            ExplanationTests.mutant(id: $0 + String(repeating: "0", count: 60))
        }
    }

    @Test("finds the one a prefix names")
    func findsByPrefix() {
        #expect(Explanation.find("cd", among: Self.mutants())?.id.hasPrefix("cd") == true)
    }

    @Test("finds one named in full")
    func findsInFull() {
        let wanted = "ab34" + String(repeating: "0", count: 60)
        #expect(Explanation.find(wanted, among: Self.mutants())?.id == wanted)
    }

    /// A prefix that names two is not an answer. Picking the first would explain a mutant
    /// nobody asked about, and they are indistinguishable from the outside.
    @Test("refuses a prefix that names more than one")
    func refusesAnAmbiguousPrefix() {
        #expect(Explanation.find("ab", among: Self.mutants()) == nil)
    }

    @Test("finds nothing for a prefix that names nothing")
    func findsNothing() {
        #expect(Explanation.find("zz", among: Self.mutants()) == nil)
    }

    /// Case is a spelling, not an identity: a digest printed by this tool is lowercase and
    /// a person pasting one back should not have to care.
    @Test("does not care how it was typed")
    func caseInsensitive() {
        #expect(Explanation.find("CD", among: Self.mutants())?.id.hasPrefix("cd") == true)
    }
}
