// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// What a run counted, and what that scores.
///
/// The summary is the first thing anybody reads, and the first thing a careful reader does
/// with it is add the columns up. So the arithmetic is a property of the type rather than
/// of whoever assembled it: a tally whose columns do not add up cannot be constructed, and
/// the columns that describe outcomes already counted elsewhere are named as such.
public struct RunSummary: Sendable, Hashable {

    /// Mutants at least one test failed on.
    public let killed: Int

    /// Mutants the whole suite passed on. Includes ``uncovered`` and ``expectedSurvivors``.
    public let survived: Int

    /// Mutants whose timeout was confirmed by a serial retry.
    public let timedOut: Int

    /// Mutants whose result was undecidable.
    public let inconclusive: Int

    /// Mutants the harness itself failed on.
    public let errored: Int

    /// Mutants nobody measured, for a reason the report carries.
    public let notRun: Int

    /// Mutants the compiler refused, with its own words beside them in the report.
    public let rejected: Int

    /// Mutants the compiler proved equivalent to the original.
    public let equivalent: Int

    /// Survivors no test reaches.
    ///
    /// A subset of ``survived``, not a column beside it. Coverage's finding is that the
    /// mutant was never executed, and "survived" is the honest reading of that.
    public let uncovered: Int

    /// Outcomes this run reused rather than measured.
    ///
    /// A subset of the measured outcomes, so it never joins the total either. It appears
    /// only when the cache was consulted.
    public let cached: Int

    /// Survivors that a `[[mutation.expect]]` row asked to be checked.
    ///
    /// A subset of ``survived``. They are evidence somebody wrote down rather than a gap,
    /// so they leave the score's denominator - but they are still counted, still executed
    /// on every invocation, and never answered from the cache.
    public let expectedSurvivors: Int

    /// How many mutants the run is about.
    ///
    /// The eight outcome columns, and only those.
    public var total: Int {
        killed + survived + timedOut + inconclusive + errored + notRun + rejected + equivalent
    }

    /// What the run scored.
    public var score: MutationScore {
        MutationScore(
            detected: killed + timedOut,
            undetected: survived - expectedSurvivors,
            uncovered: min(uncovered, survived - expectedSurvivors)
        )
    }

    /// Creates a summary, or refuses a tally that cannot describe a run.
    ///
    /// Refused: a negative count; more uncovered or expected survivors than there were
    /// survivors; and more cached outcomes than there were outcomes a cache could hold.
    /// Each of those would show up as columns that do not add up, which is worse than an
    /// error because a reader cannot tell which column is lying.
    public init?(
        killed: Int,
        survived: Int,
        timedOut: Int,
        inconclusive: Int,
        errored: Int,
        notRun: Int,
        rejected: Int,
        equivalent: Int,
        uncovered: Int,
        cached: Int,
        expectedSurvivors: Int
    ) {
        let counts = [
            killed, survived, timedOut, inconclusive, errored, notRun, rejected, equivalent,
            uncovered, cached, expectedSurvivors,
        ]
        guard counts.allSatisfy({ $0 >= 0 }) else { return nil }
        guard uncovered <= survived, expectedSurvivors <= survived else { return nil }
        // Only killed, survived and confirmed timeouts are ever stored, so nothing else
        // could have come from a cache.
        guard cached <= killed + survived + timedOut else { return nil }
        // Nothing further to check between uncovered and expected: a survivor can be
        // both, so their sum is not bounded by the number of survivors.

        self.killed = killed
        self.survived = survived
        self.timedOut = timedOut
        self.inconclusive = inconclusive
        self.errored = errored
        self.notRun = notRun
        self.rejected = rejected
        self.equivalent = equivalent
        self.uncovered = uncovered
        self.cached = cached
        self.expectedSurvivors = expectedSurvivors
    }
}
