// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import Testing

@testable import SwiftMutantsEngine

/// How many mutants a run measures at once when nobody said.
///
/// This was four, on every machine. A mutant is one test process and this tool turns the
/// suite's own in-process parallelism off, so a mutant is one busy thread: four of them on
/// a ten-core machine leaves six cores doing nothing through the longest phase of the run,
/// and the longest phase of the run is nearly all of it.
///
/// Four was not a measurement of anything. It is the number a person picks when the
/// alternative is one.
///
/// The number to pick instead is a fact about the machine rather than about this tool, and
/// it is not a stopwatch reading: the work is one independent process per mutant and the
/// machine has a known number of places to put one.
///
/// What makes raising it safe is that nothing downstream assumes it. The deadline a mutant
/// gets is derived from a baseline measured *at this width*, because a suite under load is
/// slower than a suite alone; and a suite that cannot run beside itself is caught by the
/// contended baseline, which says so and names `--jobs 1`. Both of those were built before
/// this changed, and both are why it could.
@Suite("How many at once")
struct HowManyAtOnceTests {

    /// The property, rather than the number: a machine with places to put work has work put
    /// in them. Asserting the constant would only restate it.
    @Test("uses what the machine has, rather than a number somebody picked")
    func followsTheMachine() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        #expect(Run.jobs(asked: nil) == cores)
        // The shape that matters on any machine that is not a single core: more than one.
        #expect(Run.jobs(asked: nil) > 1 || cores == 1)
    }

    /// A person who said a number meant it, including when they meant one - which is what
    /// the contended baseline tells them to say when their suite cannot run beside itself.
    @Test("does what it was told when it was told")
    func obeysWhatWasAsked() {
        #expect(Run.jobs(asked: 1) == 1)
        #expect(Run.jobs(asked: 3) == 3)
    }

    /// Nought or fewer is a configuration that would start nothing. One is the smallest
    /// number that makes progress, and a run that hangs is a worse answer than a slow one.
    @Test("never runs nothing at all")
    func neverNone() {
        #expect(Run.jobs(asked: 0) == 1)
        #expect(Run.jobs(asked: -2) == 1)
    }
}
