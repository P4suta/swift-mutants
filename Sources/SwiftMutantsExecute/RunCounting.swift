// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

extension RunSummary {

    /// Counts up what a run found.
    ///
    /// `rejected` is passed in rather than counted from the results, because a rejected
    /// mutant never ran: the compiler refused it before there was anything to run. Counting
    /// only what executed would quietly drop it from the report.
    ///
    /// `cached` likewise: an answer taken from a previous run is indistinguishable from a
    /// fresh one in the row it produces, which is the point - and a reader still has to be
    /// able to see how much of a report was measured this afternoon.
    ///
    /// `expected` is passed in because it is a fact about the configuration rather than
    /// about the results: a survivor is expected when somebody wrote it down, and nothing
    /// in the row distinguishes it from a survivor nobody did.
    public static func of(
        _ results: [MutantResult], rejected: Int = 0, cached: Int = 0, expected: Int = 0
    ) -> RunSummary? {
        var counts: [Outcome: Int] = [:]
        for result in results { counts[result.verdict.outcome, default: 0] += 1 }

        // A survivor no test reaches is a different piece of news from a survivor the
        // tests looked at and did not notice. The first is usually the cheaper thing to
        // fix - often by deleting the code rather than by writing an assertion - and it is
        // the one a reader should see first.
        let uncovered = results.count {
            $0.verdict.outcome == .survived && $0.verdict.startedTests.isEmpty
        }
        return RunSummary(
            killed: counts[.killed] ?? 0,
            survived: counts[.survived] ?? 0,
            timedOut: counts[.timedOut] ?? 0,
            inconclusive: counts[.inconclusive] ?? 0,
            errored: counts[.errored] ?? 0,
            notRun: counts[.notRun] ?? 0,
            rejected: rejected,
            equivalent: counts[.equivalent] ?? 0,
            uncovered: uncovered,
            cached: cached,
            expectedSurvivors: expected
        )
    }
}
