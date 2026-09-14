// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsExecute

/// Turning a run's answers into the counts a person reads.
///
/// Apart from the pipeline that orders the steps, because this is arithmetic rather than an
/// argument: nothing here decides what happens next, it only says what happened.
extension Run {

    /// What the answers add up to, and what they say about the project's expectations.
    ///
    /// Together because the first depends on the second: a survivor somebody wrote down
    /// leaves the score's denominator, so the tally cannot be worked out until the
    /// expectations have been.
    func account(
        _ measured: (results: [MutantResult], remembered: Int),
        rejecting rejected: Int,
        about scope: RunScope
    ) throws(RunError) -> (RunSummary, Expectations.Verdict) {
        // First answer wins, which is the catalogue's order. Two mutants cannot share an
        // identity - it is a digest of everything that distinguishes them - so this only
        // ever fires for a run that measured one twice, and taking either is the same.
        let outcomes = Dictionary(
            measured.results.map { ($0.identity.rendered, $0.verdict.outcome) },
            uniquingKeysWith: { first, _ in first })
        let expectations = Expectations.check(
            configuration.mutation.expect, against: outcomes, about: scope)
        guard
            let summary = RunSummary.of(
                measured.results,
                rejected: rejected,
                cached: measured.remembered,
                expected: expectations.met
            )
        else {
            throw RunError("the counts did not add up, which is a defect in swift-mutants")
        }
        return (summary, expectations)
    }
}
