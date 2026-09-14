// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsReport
import SwiftMutantsTUI
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
            durationMilliseconds: 231,
            index: 7
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
            durationMilliseconds: 231,
            index: 7
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

/// The command somebody pastes to watch one mutant run.
///
/// A summary says a hundred and eighty things survived. That is a number, not a task, and
/// the fastest way into one of them is to run it under a debugger. Working out how by hand
/// means knowing which bundle, which environment variable, which filter spelling and which
/// of three flags the runner adds - which is an afternoon somebody should not have to spend.
@Suite("Reproducing one mutant from a report")
struct ReproduceLineTests {

    static func invocation(
        kept: Bool = true, executable: String = "/tmp/w/PTests"
    )
        -> RunReport.Invocation
    {
        RunReport.Invocation(
            executable: executable,
            arguments: ["--quiet"],
            directory: "/tmp/w",
            eventStreamVersion: "6.3",
            environment: ["DYLD_FRAMEWORK_PATH": "/p/Developer/Library/Frameworks"],
            kept: kept
        )
    }

    static func lines(
        _ invocation: RunReport.Invocation? = nil,
        outcome: String = "survived",
        tests: [String] = ["P.S/a()"]
    ) -> [String] {
        Explanation.reproduction(
            of: ExplanationTests.mutant(outcome: outcome, testsStarted: tests.count),
            reachedBy: tests,
            with: invocation ?? Self.invocation()
        )
    }

    /// The bundle, the variable that wakes this mutant, and the tests it was offered.
    @Test("says the command that ran this mutant")
    func saysTheCommand() throws {
        let said = Self.lines().joined(separator: "\n")
        #expect(said.contains("SWIFT_MUTANTS_ACTIVE=7"))
        #expect(said.contains("/tmp/w/PTests"))
        #expect(said.contains("--filter"))
        #expect(said.contains("cd /tmp/w"))
    }

    /// It is the runner's own command, not a line assembled here. The flags the runner adds
    /// to watch a run are in it because they were in what ran.
    @Test("says the runner's command, watching flags and all")
    func saysTheRunnersCommand() throws {
        let said = Self.lines().joined(separator: "\n")
        #expect(said.contains("--no-parallel"))
        #expect(said.contains("--event-stream-version"))
        #expect(said.contains("--quiet"))
    }

    /// A run works inside a disposable copy, so the directory is usually gone by the time
    /// anybody reads this. Saying so is the difference between a line that helps and ten
    /// minutes working out why a paste failed.
    @Test("says when the tree it names is gone")
    func saysWhenTheTreeIsGone() {
        let gone = Self.lines(Self.invocation(kept: false)).joined(separator: "\n")
        #expect(gone.contains("--keep-temp"))
        let kept = Self.lines(Self.invocation(kept: true)).joined(separator: "\n")
        #expect(!kept.contains("--keep-temp"))
        #expect(kept.contains("still there"))
    }

    /// A run that never got as far as building has no command, and inventing one would be
    /// inventing the whole thing.
    @Test("says nothing when there was no command")
    func saysNothingWithoutOne() {
        #expect(Self.lines(Self.invocation(executable: "")).isEmpty)
    }

    /// A killed mutant is not a mystery somebody needs to reproduce - they have the test
    /// that caught it. The line is for the ones nothing noticed.
    @Test("says it for a survivor and not for a kill")
    func onlyForSurvivors() {
        #expect(!Self.lines(outcome: "survived").isEmpty)
        #expect(Self.lines(outcome: "killed").isEmpty)
        #expect(!Self.lines(outcome: "timed-out").isEmpty)
    }

    /// A survivor nothing reached was never offered a test, and a command filtering to none
    /// of them would run nothing at all - so it runs the suite, which is what the run did.
    @Test("runs the whole suite for a mutant nothing reached")
    func wholeSuiteForTheUnreached() {
        let said = Self.lines(tests: []).joined(separator: "\n")
        #expect(!said.contains("--filter"))
        #expect(said.contains("SWIFT_MUTANTS_ACTIVE=7"))
    }
}

/// What a browser is handed.
///
/// The browser itself is tested against rows; this is about which rows it gets, and the
/// answer is the survivors. A killed mutant is not a thing to walk through - whoever reads
/// it already has the test that caught it, which beats anything a browser could show.
@Suite("What a browser is handed")
struct BrowseRowsTests {

    static func report(_ outcomes: [Outcome]) -> RunReport {
        RunReport(
            of: NarrationFixture.outcome(
                results: outcomes.map { outcome in
                    NarrationFixture.result(
                        outcome, tests: outcome == .survived ? [] : ["MathTests/testAdd"])
                }
            ))
    }

    @Test("hands it the survivors and nothing else")
    func survivorsOnly() {
        let rows = BrowseCommand.rows(of: Self.report([.survived, .killed, .survived]))
        #expect(rows.count == 2)
    }

    /// Everything `explain` would say, because that is what somebody opened it for.
    @Test("hands it everything explain would say about one")
    func theWholeStory() throws {
        let rows = BrowseCommand.rows(of: Self.report([.survived]))
        let row = try #require(rows.first)
        #expect(row.identity.count == 64)
        #expect(row.place.contains(".swift"))
        #expect(row.story.contains { $0.contains("no test reaches this") })
    }

    @Test("says nothing to walk through when nothing survived")
    func nothingSurvived() {
        #expect(BrowseCommand.rows(of: Self.report([.killed])).isEmpty)
    }
}
