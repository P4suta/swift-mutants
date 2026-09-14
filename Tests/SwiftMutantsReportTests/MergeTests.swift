// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsReport

/// Putting the shares back together.
///
/// Five machines measure a fifth each and produce five reports, each of which holds every
/// mutant and an answer for a fifth of them. None of them is the answer, and a person
/// reading any one of them would read a score about a fifth of a package.
///
/// The merge is the arithmetic nobody should do by hand: every mutant once, with the answer
/// from whichever share measured it, and the counts recomputed from that rather than added
/// up from five summaries that each counted the others as `not-run`.
@Suite("Merging shares")
struct MergeTests {

    static func mutant(
        _ name: String, _ outcome: String, tests: [Int] = []
    ) -> RunReport.Mutant {
        RunReport.Mutant(
            id: Digest.of(name).hexadecimal,
            path: "Sources/A.swift",
            line: .init(1),
            column: .init(1),
            span: RunReport.Span(start: 0, end: 1),
            rule: "lt-to-le@1",
            original: "<",
            replacement: "<=",
            outcome: outcome,
            killedBy: outcome == "killed" ? ["t"] : [],
            ran: tests,
            testsStarted: tests.count,
            attempts: outcome == "not-run" ? 0 : 1,
            durationMilliseconds: 1
        )
    }

    static func share(
        _ index: Int, _ mutants: [RunReport.Mutant], tests: [String] = ["t"]
    )
        -> RunReport
    {
        RunReportTests.report(results: []).replacing(
            mutants: mutants, tests: tests, shard: "\(index)/3")
    }

    @Test("keeps every mutant once")
    func everyMutantOnce() throws {
        let merged = try #require(
            Merge.of([
                Self.share(
                    1, [Self.mutant("a", "killed", tests: [0]), Self.mutant("b", "not-run")]),
                Self.share(
                    2, [Self.mutant("a", "not-run"), Self.mutant("b", "survived", tests: [0])]),
            ]))
        #expect(merged.mutants.count == 2)
        #expect(Set(merged.mutants.map(\.id)).count == 2)
    }

    /// The answer comes from whichever share measured it. A share that did not is not a
    /// vote for `not-run`; it is a share that was not asked.
    @Test("takes each answer from the machine that measured it")
    func takesTheMeasuredAnswer() throws {
        let merged = try #require(
            Merge.of([
                Self.share(
                    1, [Self.mutant("a", "killed", tests: [0]), Self.mutant("b", "not-run")]),
                Self.share(
                    2, [Self.mutant("a", "not-run"), Self.mutant("b", "survived", tests: [0])]),
            ]))
        let byId = Dictionary(uniqueKeysWithValues: merged.mutants.map { ($0.id, $0.outcome) })
        #expect(byId[Digest.of("a").hexadecimal] == "killed")
        #expect(byId[Digest.of("b").hexadecimal] == "survived")
    }

    /// Recomputed, not added up. Five summaries that each counted the others as `not-run`
    /// would sum to four fifths of the catalogue being unmeasured.
    @Test("counts the merged answers rather than adding up the summaries")
    func recountsFromScratch() throws {
        let merged = try #require(
            Merge.of([
                Self.share(
                    1, [Self.mutant("a", "killed", tests: [0]), Self.mutant("b", "not-run")]),
                Self.share(
                    2, [Self.mutant("a", "not-run"), Self.mutant("b", "survived", tests: [0])]),
            ]))
        #expect(merged.summary.killed == 1)
        #expect(merged.summary.survived == 1)
        #expect(merged.summary.notRun == 0)
        #expect(merged.summary.score.value == 0.5)
    }

    /// A mutant nothing measured stays `not-run` and stays out of the score. It is honest
    /// about a machine that never reported rather than quietly counting it as a survivor.
    @Test("keeps a mutant no machine measured out of the score")
    func unmeasuredStaysOut() throws {
        let merged = try #require(
            Merge.of([
                Self.share(
                    1, [Self.mutant("a", "killed", tests: [0]), Self.mutant("b", "not-run")])
            ]))
        #expect(merged.summary.notRun == 1)
        #expect(merged.summary.score.value == 1)
    }

    /// The test names are a list per report, and a position in one list means nothing in
    /// another. Merging them without renumbering would put one share's test names against
    /// another share's mutants.
    @Test("renumbers the tests each share named")
    func renumbersTests() throws {
        let merged = try #require(
            Merge.of([
                Self.share(1, [Self.mutant("a", "survived", tests: [0])], tests: ["first"]),
                Self.share(2, [Self.mutant("b", "survived", tests: [0])], tests: ["second"]),
            ]))
        #expect(Set(merged.tests) == ["first", "second"])
        let names = merged.mutants.map { $0.ran.map { merged.tests[$0] } }
        #expect(Set(names.flatMap { $0 }) == ["first", "second"])
    }

    /// A merged report is about the package, not about a share, and it says so.
    @Test("is about the whole package again")
    func noLongerAShare() throws {
        let merged = try #require(
            Merge.of([Self.share(1, [Self.mutant("a", "killed", tests: [0])])]))
        #expect(merged.scope.shard.value == nil)
    }

    @Test("refuses to merge nothing")
    func refusesNothing() {
        #expect(Merge.of([]) == nil)
    }

    /// Two reports about different packages are not two shares of one run, and merging them
    /// would produce a score about a program nobody has.
    @Test("refuses shares that are not of the same catalogue")
    func refusesDifferentPackages() {
        let one = Self.share(1, [Self.mutant("a", "killed", tests: [0])])
        let other = RunReportTests.report(results: []).replacing(
            mutants: [Self.mutant("a", "killed", tests: [0])],
            tests: ["t"],
            shard: "1/3",
            files: ["Sources/Other.swift": "deadbeef"]
        )
        #expect(Merge.of([one, other]) == nil)
    }
}
