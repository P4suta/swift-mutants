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
    ///
    /// ## Cores are not the only thing a trial needs
    ///
    /// A mutant is a test bundle loaded into a process, and a machine with more cores than
    /// memory to put a bundle in for each of them runs out of memory rather than out of
    /// cores. Reported from a run killed by its harness for memory pressure at 755 of 755 -
    /// after every answer was in, which is the most expensive moment there is to be killed.
    ///
    /// **Physical** memory, not free memory. Free memory changes second to second, so
    /// choosing the width from it would make a run's shape depend on whatever happened to
    /// be running at second zero - the class of dependency this tool removed from its
    /// verdicts, and it has no more business deciding the width than it had deciding a
    /// deadline. The cost of that choice is honest and worth stating: this does **not**
    /// help a machine that is busy with something else. That machine wants `--jobs`, and
    /// nothing derivable can tell it apart from an idle one of the same size.
    static func jobs(
        asked: Int?,
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        guard asked == nil else { return max(1, asked ?? 1) }
        let room = Int(memoryBytes / 2 / UInt64(Self.trialMemoryBytes))
        return max(1, min(max(cores, 1), room))
    }

    /// What one trial is assumed to need.
    ///
    /// A gibibyte, which is also the floor the memory limit uses. An assumption rather than
    /// a measurement, and the reason is worth writing down rather than leaving as a gap:
    /// what a trial actually costs could be measured from the solitary baseline, but only
    /// through a wrapper that reports peak resident size - and the two programs that do
    /// (`/usr/bin/time -l` on Darwin, `-v` on Linux) print different words for it. That is
    /// two parsers for a number whose only use is to divide a machine in half.
    ///
    /// Wrong in the generous direction for a small suite and the tight direction for a
    /// package whose bundle is enormous. The second is the one that would hurt, and it
    /// hurts by being slow rather than by being killed.
    static let trialMemoryBytes = 1 << 30

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
        from baseline: Verdict,
        cheapestTrial: Int?,
        asked: Duration?,
        cheapestTrialCpu: Int? = nil
    ) -> Budget {
        if let asked { return .flat(asked) }
        return Budget.deriving(
            suiteMilliseconds: max(baseline.durationMilliseconds, 1),
            tests: baseline.testsStarted,
            oneTestMilliseconds: cheapestTrial,
            // The same suite measured in the unit the work is done in. A deadline derived
            // from wall time is a statement about the machine as much as about the suite;
            // an allowance derived from this one is a statement about the suite alone, and
            // it is what actually stops a mutant that does not terminate.
            cpuSuiteMilliseconds: baseline.cpuMilliseconds,
            cpuOneTestMilliseconds: cheapestTrialCpu
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
