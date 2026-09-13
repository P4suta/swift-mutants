// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// What a run counted.
///
/// The arithmetic is enforced rather than trusted, because the summary is the first thing
/// anybody reads and a reader who adds the columns up and gets a different number has no
/// way to tell which of them is wrong.
@Suite("Run summary")
struct RunSummaryTests {

    static func summary(
        killed: Int = 0,
        survived: Int = 0,
        timedOut: Int = 0,
        inconclusive: Int = 0,
        errored: Int = 0,
        notRun: Int = 0,
        rejected: Int = 0,
        equivalent: Int = 0,
        uncovered: Int = 0,
        cached: Int = 0,
        expected: Int = 0
    ) -> RunSummary? {
        RunSummary(
            killed: killed,
            survived: survived,
            timedOut: timedOut,
            inconclusive: inconclusive,
            errored: errored,
            notRun: notRun,
            rejected: rejected,
            equivalent: equivalent,
            uncovered: uncovered,
            cached: cached,
            expectedSurvivors: expected
        )
    }

    @Test("counts every outcome once towards the total")
    func totalIsTheSumOfTheOutcomes() throws {
        let summary = try #require(
            Self.summary(
                killed: 10,
                survived: 3,
                timedOut: 1,
                inconclusive: 2,
                errored: 1,
                notRun: 4,
                rejected: 5,
                equivalent: 2
            )
        )
        #expect(summary.total == 28)
    }

    /// `uncovered` and `cached` describe outcomes that are already counted, so adding them
    /// to the total would make the columns stop adding up - which is exactly what a reader
    /// checks first.
    @Test("does not count a subset column twice")
    func subsetColumnsAreNotAddedAgain() throws {
        let summary = try #require(Self.summary(killed: 2, survived: 3, uncovered: 3, cached: 5))
        #expect(summary.total == 5)
    }

    @Test("scores what was measured, excluding what was not")
    func scoreExcludesTheUnmeasured() throws {
        let summary = try #require(
            Self.summary(
                killed: 9,
                survived: 3,
                timedOut: 1,
                inconclusive: 2,
                errored: 1,
                notRun: 4,
                rejected: 5,
                equivalent: 2,
                uncovered: 2
            )
        )
        // detected = 9 killed + 1 confirmed timeout; undetected = 3 survived.
        #expect(summary.score.valid == 13)
        #expect(summary.score.covered == 11)
        #expect(summary.score.rendered == "76.92%")
    }

    /// A mutant named in `[[mutation.expect]]` is evidence somebody asked to be checked,
    /// not a gap. It survives on purpose, so it leaves the denominator.
    @Test("keeps an expected survivor out of the denominator")
    func expectedSurvivorsLeaveTheDenominator() throws {
        let summary = try #require(Self.summary(killed: 3, survived: 2, expected: 1))
        #expect(summary.total == 5)
        #expect(summary.score.valid == 4)
        #expect(summary.score.rendered == "75.00%")
    }

    @Test(
        "refuses a tally that cannot describe a run",
        arguments: [
            ("negative count", -1, 0, 0, 0),
            ("more uncovered than survived", 0, 2, 3, 0),
            ("more expected than survived", 0, 2, 0, 3),
            ("more cached than measured", 1, 0, 0, 0),
        ]
    )
    func refusesImpossibleTallies(
        reason: String, killed: Int, survived: Int, uncovered: Int, expected: Int
    ) {
        let cached = reason == "more cached than measured" ? 9 : 0
        #expect(
            Self.summary(
                killed: killed,
                survived: survived,
                uncovered: uncovered,
                cached: cached,
                expected: expected
            ) == nil,
            "\(reason) was accepted"
        )
    }

    @Test("holds a run that measured nothing")
    func emptyRun() throws {
        let summary = try #require(Self.summary())
        #expect(summary.total == 0)
        #expect(summary.score.value == nil)
        #expect(summary.score.rendered == "N/A")
    }
}
