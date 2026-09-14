// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsValidate
import Testing

@testable import SwiftMutantsCLI

/// What a run says about itself.
///
/// The narration is the whole product for anybody who does not read JSON, and it was the
/// one surface with no test on it: a phase could stop announcing itself, or announce a
/// number that was not true, and every other test in this package would still pass. These
/// hold the words.
@Suite("Narration")
struct NarrationTests {

    @Test("names each phase it passes through")
    func namesEachPhase() {
        #expect(Narration.line(for: .snapshotting) == "copying the package")
        #expect(Narration.line(for: .discovering) == "reading the sources")
        #expect(Narration.line(for: .proving) == "proving every mutant is in the tree")
        #expect(Narration.line(for: .building) == "building the tests, once")
        #expect(Narration.line(for: .baseline) == "running the tests with nothing awake")
    }

    @Test("says how much it instrumented and where")
    func saysWhatItInstrumented() {
        #expect(
            Narration.line(for: .instrumenting(files: 61, mutants: 646))
                == "instrumenting 646 mutants across 61 files"
        )
    }

    /// Every stage must say something or deliberately say nothing. A stage that fell
    /// through to `nil` by accident is a phase that runs silently, which is the failure
    /// mode this narration exists to prevent.
    @Test("leaves no phase silent by accident")
    func nothingIsSilent() {
        let stages: [RunStage] = [
            .snapshotting, .discovering, .instrumenting(files: 1, mutants: 1),
            .validating(.compiling(round: 1, mutants: 1)), .building, .proving, .baseline,
            .calibrated(.seconds(1)), .probing(tests: 1),
            .covered(uncovered: 1, averageTests: 1), .scoped(since: "HEAD", files: 1),
            .running(total: 1, processes: 1),
        ]
        for stage in stages {
            #expect(Narration.line(for: stage) != nil, "\(stage) says nothing")
        }
    }

    /// `.finished` is the one stage that is deliberately silent here: it arrives once per
    /// mutant and is counted rather than narrated, because a line each would bury the
    /// handful a person can act on.
    @Test("says nothing for each finished mutant")
    func finishedIsCountedNotSaid() {
        let result = NarrationFixture.result(.survived, tests: [])
        #expect(Narration.line(for: .finished(result)) == nil)
    }
}

/// The lines that carry a number.
@Suite("Narrating numbers")
struct NarrationNumberTests {

    @Test("says where the deadline came from")
    func saysWhereTheDeadlineCameFrom() {
        #expect(
            Narration.line(for: .calibrated(.seconds(37)))
                == "  giving each mutant 37 seconds, from how long that took"
        )
    }

    @Test("says how many tests it asked")
    func saysHowManyTestsItAsked() {
        #expect(
            Narration.line(for: .probing(tests: 610))
                == "asking each of 610 tests what it reaches"
        )
    }

    /// The number that justifies the whole coverage pass: a mutant faces a handful of
    /// tests instead of the suite.
    @Test("says what the coverage bought")
    func saysWhatCoverageBought() {
        #expect(
            Narration.line(for: .covered(uncovered: 74, averageTests: 39.28))
                == "  nothing reaches 74 of them; the rest face 39.3 tests each, "
                + "not the whole suite"
        )
    }

    @Test("rounds an average to one place")
    func roundsToOnePlace() {
        #expect(Narration.oneDecimal(0) == "0.0")
        #expect(Narration.oneDecimal(39.28) == "39.3")
        #expect(Narration.oneDecimal(2.04) == "2.0")
        #expect(Narration.oneDecimal(-1.25) == "-1.3")
    }

    @Test("says what a scoped run is about")
    func saysWhatAScopedRunIsAbout() {
        #expect(
            Narration.line(for: .scoped(since: "main", files: 4))
                == "measuring only what changed since main: 4 files"
        )
    }

    /// Nothing to measure is news, not an empty list. A run that said "measuring 0 files"
    /// and then scored 100% would be read as a pass.
    @Test("says plainly when nothing changed")
    func saysWhenNothingChanged() {
        #expect(
            Narration.line(for: .scoped(since: "main", files: 0))
                == "nothing has changed since main"
        )
    }

    /// The saving, said out loud: a number a reader can check against the run.
    @Test("says how many processes the mutants will take")
    func saysHowManyProcesses() {
        #expect(
            Narration.line(for: .running(total: 671, processes: 96))
                == "running 671 mutants in 96 processes"
        )
    }

    /// With no coverage there is no saving, and claiming one would be a lie a reader has
    /// no way to catch.
    @Test("claims no saving when there is none")
    func claimsNoSavingWhenThereIsNone() {
        #expect(Narration.line(for: .running(total: 671, processes: 671)) == "running 671 mutants")
    }
}

/// What validation says while it runs, which is the slowest and quietest phase there is.
@Suite("Narrating validation")
struct NarrationValidationTests {

    /// "Asking", not "building". A round is every module of the package lowered at once,
    /// separately - not a build - except when the plan cannot be read and it falls back to
    /// one. A word true of only one of those would be a lie half the time.
    @Test("says the first round is about every mutant")
    func firstRound() {
        #expect(
            Narration.validating(.compiling(round: 1, mutants: 646))
                == "asking the compiler about all 646 mutants at once"
        )
    }

    /// A second round is progress, and the count shrinking is the evidence of it. Without
    /// this line a reader cannot tell a second build from a hang.
    @Test("says a later round is smaller")
    func laterRound() {
        #expect(
            Narration.validating(.compiling(round: 2, mutants: 611))
                == "  asking again, 611 left"
        )
    }

    @Test("says how many the compiler refused")
    func refused() {
        #expect(Narration.validating(.refused(round: 1, count: 35)) == "  the compiler refused 35")
    }

    /// Halving is the expensive path, and the reason for it is a diagnostic nobody could
    /// place. Printing that diagnostic is the only way a reader learns why - it exists
    /// only while the tree is instrumented and is gone by the time the run ends.
    @Test("says why it had to halve, in the compiler's words")
    func halvingSaysWhy() {
        let diagnostic = CompilerDiagnostic(
            file: "Sources/Codec/Header.swift",
            position: SourcePosition(line: 12, column: 30),
            severity: .error,
            message: "no such module 'Core'"
        )
        #expect(
            Narration.validating(.halving(mutants: 646, unplaceable: diagnostic))
                == """
                  the compiler would not say which, so halving 646 mutants
                  it said: Sources/Codec/Header.swift:12:30: no such module 'Core'
                """
        )
    }

    @Test("halves without a diagnostic when there is none to give")
    func halvingWithoutOne() {
        #expect(
            Narration.validating(.halving(mutants: 646, unplaceable: nil))
                == "  the compiler would not say which, so halving 646 mutants"
        )
    }
}

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
