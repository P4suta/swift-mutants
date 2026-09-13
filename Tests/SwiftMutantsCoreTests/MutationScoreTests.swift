// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// What a run reports, and what it refuses to report.
@Suite("Mutation score")
struct MutationScoreTests {

    @Test("is detected over valid")
    func isDetectedOverValid() {
        let score = MutationScore(detected: 3, undetected: 1, uncovered: 0)
        #expect(score.valid == 4)
        #expect(score.value == 0.75)
    }

    /// Two numbers, because they answer different questions and demand different fixes.
    /// The overall score says how much of the code is protected; the covered-code score
    /// says how good the tests that exist are. A module with no tests and a module with
    /// useless tests score the same on the first and very differently on the second.
    @Test("reports covered code separately from the whole")
    func reportsCoveredCodeSeparately() {
        let score = MutationScore(detected: 3, undetected: 5, uncovered: 4)
        #expect(score.valid == 8)
        #expect(score.covered == 4)
        #expect(score.value == 0.375)
        #expect(score.ofCoveredCode == 0.75)
    }

    /// An uncovered mutant survived; it is not a seventh bucket. If it were counted
    /// separately the columns would stop adding up to the number of mutants, and a reader
    /// checking the arithmetic of a report would find it wrong.
    @Test("counts an uncovered mutant among the undetected, not beside them")
    func uncoveredIsASubsetOfUndetected() {
        let score = MutationScore(detected: 1, undetected: 4, uncovered: 4)
        #expect(score.valid == 5)
        #expect(score.covered == 1)
        #expect(score.value == 0.2)
        #expect(score.ofCoveredCode == 1.0)
    }

    /// Both plausible sentinels are lies: zero reads as "your tests caught nothing" and one
    /// as "your tests caught everything", when the truth is that nothing was measured.
    @Test("has no value at all when nothing scoreable was measured")
    func hasNoValueWhenNothingWasMeasured() {
        let score = MutationScore(detected: 0, undetected: 0, uncovered: 0)
        #expect(score.valid == 0)
        #expect(score.value == nil)
        #expect(score.ofCoveredCode == nil)
        #expect(score.rendered == "N/A")
        #expect(score.renderedForCoveredCode == "N/A")
    }

    /// A run where every mutant survived and none was covered has a covered-code score of
    /// nothing rather than of zero: no test reached any of them, so the tests that exist
    /// were never asked.
    @Test("has no covered-code value when no mutant was covered")
    func hasNoCoveredValueWhenNothingWasCovered() {
        let score = MutationScore(detected: 0, undetected: 6, uncovered: 6)
        #expect(score.value == 0.0)
        #expect(score.ofCoveredCode == nil)
        #expect(score.rendered == "0.00%")
        #expect(score.renderedForCoveredCode == "N/A")
    }

    /// Humans get two decimal places; the JSON keeps the full value, because a report is
    /// also an input to `report merge` and to a threshold comparison.
    @Test(
        "renders to two decimal places without disturbing the value",
        arguments: [
            (1, 2, "33.33%"), (2, 1, "66.67%"), (1, 0, "100.00%"), (0, 1, "0.00%"),
        ]
    )
    func rendersToTwoDecimalPlaces(detected: Int, undetected: Int, expected: String) {
        let score = MutationScore(detected: detected, undetected: undetected, uncovered: 0)
        #expect(score.rendered == expected)
    }

    /// A timeout that was confirmed by a serial retry is a detection: in CI the loop it
    /// created would have failed the build. It is counted in the score and displayed apart
    /// from kills, which is the caller's business rather than this type's.
    @Test("treats a confirmed timeout as detected")
    func confirmedTimeoutCountsAsDetected() {
        let killsOnly = MutationScore(detected: 2, undetected: 2, uncovered: 0)
        let killsAndTimeout = MutationScore(
            killed: 1, confirmedTimeouts: 1, undetected: 2, uncovered: 0)
        #expect(killsOnly == killsAndTimeout)
    }

    @Test(
        "refuses a tally that cannot describe a run",
        arguments: [
            (-1, 0, 0), (0, -1, 0), (0, 0, -1), (1, 1, 2),
        ])
    func refusesImpossibleTallies(detected: Int, undetected: Int, uncovered: Int) {
        #expect(
            MutationScore(checking: detected, undetected: undetected, uncovered: uncovered) == nil
        )
    }
}

/// The vocabulary a run uses to say what became of a mutant.
@Suite("Outcome")
struct OutcomeTests {

    /// Hyphenated in JSON, camel-cased in Swift. The sibling projects spell outcome values
    /// with hyphens while summary *keys* are snake_case, and note that the difference is
    /// deliberate and must not be unified by anybody tidying up.
    @Test(
        "spells itself the way the report schema does",
        arguments: [
            (Outcome.killed, "killed"),
            (.survived, "survived"),
            (.timedOut, "timed-out"),
            (.inconclusive, "inconclusive"),
            (.errored, "errored"),
            (.notRun, "not-run"),
            (.rejected, "rejected"),
            (.equivalent, "equivalent"),
        ]
    )
    func spelling(outcome: Outcome, expected: String) {
        #expect(outcome.rawValue == expected)
    }

    @Test("knows which outcomes count as a detection")
    func detection() {
        #expect(Outcome.allCases.filter(\.isDetection) == [.killed, .timedOut])
    }

    /// Everything that is a statement about the run rather than about the tests stays out
    /// of the denominator: an inconclusive result, a harness error, a mutant nobody ran, a
    /// mutant the compiler refused, and one the compiler proved equivalent.
    @Test("knows which outcomes are scoreable")
    func scoreable() {
        #expect(Outcome.allCases.filter(\.isScoreable) == [.killed, .survived, .timedOut])
    }
}
