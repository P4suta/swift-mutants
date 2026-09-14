// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import Testing

@testable import SwiftMutantsCLI

/// How a finished run accounts for itself.
@Suite("Narrating a summary")
struct NarrationSummaryTests {

    @Test("splits survivors nothing reaches from survivors nothing noticed")
    func splitsSurvivors() {
        let results = [
            NarrationFixture.result(.survived, tests: []),
            NarrationFixture.result(.survived, tests: ["MathTests/testAdd"]),
            NarrationFixture.result(.killed, tests: ["MathTests/testAdd"]),
        ]
        let lines = Narration.summary(of: NarrationFixture.outcome(results: results))
        #expect(lines.contains("no test reaches these:"))
        #expect(lines.contains("these ran and nothing noticed:"))
        // One line under each heading, and the killed mutant under neither.
        #expect(lines.count { $0.hasPrefix("  ") } == 2)
    }

    /// A heading with nothing under it reads as a claim that the list is empty when it was
    /// never gathered. Silence is the honest shape.
    @Test("prints no heading for a kind of survivor it has none of")
    func noEmptyHeadings() {
        let results = [NarrationFixture.result(.survived, tests: [])]
        let lines = Narration.summary(of: NarrationFixture.outcome(results: results))
        #expect(lines.contains("no test reaches these:"))
        #expect(!lines.contains("these ran and nothing noticed:"))
    }

    @Test("names each survivor by file, identity and rule")
    func namesEachSurvivor() {
        let result = NarrationFixture.result(.survived, tests: [])
        let line = Narration.describe(result)
        #expect(line.contains("Sources/Codec/Header.swift"))
        #expect(line.contains(result.identity.shortForm))
        #expect(line.contains("lt-to-le"))
    }

    /// Every outcome column, every time - including the zeroes. A column that vanished
    /// when it was zero would make two runs of the same package print different shapes,
    /// and a reader counting columns would misread the one that was left.
    @Test("prints every column even when it is zero")
    func printsEveryColumn() throws {
        let lines = Narration.summary(of: NarrationFixture.outcome(results: []))
        let counts = try #require(lines.first { $0.contains("killed") })
        #expect(
            counts == "0 killed  0 survived (0 of them unreached)  0 rejected  "
                + "0 timed out  0 errored"
        )
    }

    @Test("prints both scores, because they answer different questions")
    func printsBothScores() {
        let counts = NarrationFixture.counts(killed: 3, survived: 1, uncovered: 1)
        let lines = Narration.summary(
            of: NarrationFixture.outcome(results: [], summary: counts)
        )
        // 3 of 4 overall; 3 of the 3 a test reached.
        #expect(lines.last == "score 75.00%  of covered code 100.00%")
    }

    /// A run that measured nothing scores nothing. Printing 0% would read as "caught
    /// none", and 100% as "caught all" - both of which are claims about tests that never
    /// ran.
    @Test("refuses to invent a score out of no mutants")
    func noScoreWithoutMutants() {
        let lines = Narration.summary(of: NarrationFixture.outcome(results: []))
        #expect(lines.last == "score N/A  of covered code N/A")
    }
}

/// The pieces a narration test needs, built once and named.
///
/// `RuleIdentifier`, `SourceSpan` and `WorkspaceRelativePath` all refuse malformed input,
/// which is right for a library and noisy in a fixture. Refusing here is a bug in the
/// fixture rather than a fact about the code under test, so it stops the process with the
/// reason instead of failing an expectation about narration.
enum NarrationFixture {

    static let path: WorkspaceRelativePath = build("Sources/Codec/Header.swift")

    static let rule: RuleIdentifier = build("lt-to-le@1")

    static let span: SourceSpan = build(start: 10, end: 11)

    private static func build(_ spelling: String) -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath(spelling) else {
            fatalError("malformed fixture path")
        }
        return path
    }

    private static func build(_ spelling: String) -> RuleIdentifier {
        guard let rule = RuleIdentifier(spelling) else {
            fatalError("malformed fixture rule")
        }
        return rule
    }

    private static func build(start: Int, end: Int) -> SourceSpan {
        guard let span = SourceSpan(start: start, end: end) else {
            fatalError("malformed fixture span")
        }
        return span
    }

    private static func tally(_ counts: RunSummary?) -> RunSummary {
        guard let counts else { fatalError("malformed fixture tally") }
        return counts
    }

    /// What the tests said about one mutant.
    static func verdict(_ outcome: Outcome, tests: [String]) -> Verdict {
        Verdict(
            outcome: outcome,
            killedBy: outcome == .killed ? tests : [],
            firstFailure: outcome == .killed ? tests.first : nil,
            startedTests: tests,
            durationMilliseconds: 1,
            termination: .exited(0)
        )
    }

    /// One mutant, at a fixed place, with a fixed name.
    static func result(_ outcome: Outcome, tests: [String]) -> MutantResult {
        MutantResult(
            identity: MutantIdentity(
                MutantIdentity.Inputs(
                    path: path,
                    enclosingDeclaration: "s:7Example1fyySiF",
                    rule: rule,
                    span: span,
                    sourceDigest: Digest.of("a < b"),
                    originalBytes: Digest.of("<"),
                    replacementBytes: Digest.of("<=")
                )
            ),
            path: path,
            rule: rule,
            span: span,
            verdict: verdict(outcome, tests: tests),
            attempts: 1
        )
    }

    /// A finished run whose counts follow from its results, unless given otherwise.
    static func outcome(results: [MutantResult], summary: RunSummary? = nil) -> RunOutcome {
        let derived = counts(
            killed: results.count { $0.verdict.outcome == .killed },
            survived: results.count { $0.verdict.outcome == .survived },
            uncovered: results.count {
                $0.verdict.outcome == .survived && $0.verdict.startedTests.isEmpty
            }
        )
        return RunOutcome(
            results: results,
            rejected: [],
            summary: summary ?? derived,
            baseline: verdict(.survived, tests: []),
            contendedBaseline: verdict(.survived, tests: []),
            filesInstrumented: 1,
            scope: .everything
        )
    }

    /// A tally, spelled out only where a test is about the tally itself.
    static func counts(killed: Int, survived: Int, uncovered: Int) -> RunSummary {
        tally(
            RunSummary(
                killed: killed,
                survived: survived,
                timedOut: 0,
                inconclusive: 0,
                errored: 0,
                notRun: 0,
                rejected: 0,
                equivalent: 0,
                uncovered: uncovered,
                cached: 0,
                expectedSurvivors: 0
            )
        )
    }
}

extension NarrationNumberTests {

    /// A probe that did not finish costs a slower run and prevents a wrong one, and both
    /// halves of that deserve to be said.
    @Test("says how many tests it could not measure")
    func saysWhatItCouldNotMeasure() {
        #expect(
            Narration.line(for: .unmeasured(tests: 3))
                == "  3 of them did not finish, so every mutant is offered them"
        )
    }

    /// The largest saving this tool has, and the one easiest to be wrong about. A reader
    /// who sees six hundred mutants answered in a second deserves to be told why.
    @Test("says how many answers came from an earlier run")
    func saysWhatItRemembered() {
        #expect(
            Narration.line(for: .remembered(known: 612, total: 671))
                == "612 of 671 were answered by an earlier run and are not run again"
        )
    }
}
