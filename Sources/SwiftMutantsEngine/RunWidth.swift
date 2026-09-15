// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

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
}
