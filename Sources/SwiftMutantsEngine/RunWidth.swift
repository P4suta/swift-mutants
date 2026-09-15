// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public import SwiftMutantsExecute

/// How wide a run is: how many of everything it may have running at once.
///
/// One number for every kind of process this tool starts, because a person who turned
/// it down because their machine was struggling meant it about all of them.
extension Run {

    /// How many mutants to measure at once.
    ///
    /// What the machine has, when nobody said. This was four, on every machine - a mutant
    /// is one test process and this tool turns the suite's own in-process parallelism off,
    /// so a mutant is one busy thread, and four of them on a ten-core machine leaves six
    /// cores doing nothing through the longest phase of a run. Four was not a measurement
    /// of anything; it is the number a person picks when the alternative is one.
    ///
    /// A fact about the machine rather than about this tool, and not a stopwatch reading:
    /// the work is one independent process per mutant, and the machine has a known number
    /// of places to put one.
    ///
    /// What makes it safe to follow the machine is that nothing downstream assumes the
    /// number. A mutant's deadline is derived from a baseline measured *at this width*,
    /// because a suite under load is slower than a suite alone; and a suite that cannot
    /// run beside itself is caught by the contended baseline, which says so and names
    /// `--jobs 1`. Both were built before this changed, and both are why it could.
    ///
    /// Never fewer than one, whatever was asked: a run that starts nothing is worse than a
    /// run that is slow.
    static func jobs(asked: Int?) -> Int {
        guard let asked else { return max(1, ProcessInfo.processInfo.activeProcessorCount) }
        return max(1, asked)
    }

    /// How long the baseline itself is given, before anything is known about the suite.
    ///
    /// Generous, because it is spent once and the alternative is a run that gives up on a
    /// package whose tests are simply long.
    public static let calibrationBudget: Duration = .seconds(1800)

    /// How long one mutant gets, once the run knows how much of the suite it faces.
    ///
    /// This was one number for every mutant - five times the whole contended suite, floor
    /// of thirty seconds - and coverage was not consulted at all. Coverage is this tool's
    /// largest saving and it was being spent in one direction only: a mutant reached by
    /// forty-five of a package's 1333 tests ran forty-five tests and was then given the
    /// budget of all 1333. Reported from a real package: 898 seconds for a trial that
    /// runs 3.4% of the suite.
    ///
    /// ``Budget`` carries the shape and the reasoning; this supplies the measurements.
    /// The suite's cost is the *contended* baseline, because that is the figure the
    /// mutants will live under - measured here, thirty-five seconds alone and over five
    /// times that with eight at once. The intercept is the cheapest thing the probe phase
    /// saw, which is a trial that ran one test, on this machine, under this contention.
    ///
    /// The asymmetry still sets the direction. A deadline met under load costs one serial
    /// retry; a deadline set too tight reports a survivor as a detection, which is the
    /// mistake nobody ever finds out about.
    public static func budget(
        from baseline: Verdict, cheapestTrial: Int?, asked: Duration?
    ) -> Budget {
        if let asked { return .flat(asked) }
        return Budget.deriving(
            suiteMilliseconds: max(baseline.durationMilliseconds, 1),
            tests: baseline.testsStarted,
            oneTestMilliseconds: cheapestTrial
        )
    }

    /// Where the instrumented copy is built.
    ///
    /// Inside the copy, where the package expects to be built, rather than off to one
    /// side. A test that reaches for something the build produced - a helper executable, a
    /// generated resource, a fixture binary - looks in `.build` relative to its package,
    /// and a build placed anywhere else leaves it looking at nothing. Measured on this
    /// repository: twelve tests failed with nothing awake because the scripted toolchain
    /// they drive was built somewhere they do not look.
    ///
    /// Nothing is polluted by this. The copy is disposable and the tree the user pointed
    /// at is never written to at all.
}
