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

    /// Cores are not the only thing a trial needs.
    ///
    /// A mutant is a test bundle loaded into a process, and a machine with more cores than
    /// memory to put a bundle in for each of them runs out of memory rather than out of
    /// cores. Reported from a run killed by its harness for memory pressure at 755 of 755 -
    /// after every answer was in, which is the most expensive moment to be killed.
    ///
    /// Physical memory rather than free memory, deliberately. Free memory changes second to
    /// second, so choosing the width from it would make a run's shape depend on whatever
    /// happened to be running at second zero - which is the class of dependency this tool
    /// spent yesterday removing from its verdicts, and it has no more business deciding the
    /// width than it had deciding a deadline.
    @Test("never asks for more trials at once than there is memory to hold one each")
    func boundedByMemory() {
        // A machine with plenty of cores and little memory: the memory decides.
        #expect(Run.jobs(asked: nil, cores: 16, memoryBytes: 8 << 30) == 4)
        // And one with plenty of memory: the cores decide, as before.
        #expect(Run.jobs(asked: nil, cores: 18, memoryBytes: 48 << 30) == 18)
    }

    /// Half the machine, because the other half is the operating system, the editor, the
    /// build cache and whatever else the person is doing. A tool that helped itself to all
    /// of a machine would be a tool people run once.
    @Test("leaves half the machine to everything else")
    func leavesRoom() {
        #expect(Run.jobs(asked: nil, cores: 64, memoryBytes: 16 << 30) == 8)
    }

    /// Never nought, however small the machine. One at a time is slow; none at a time is a
    /// run that answers nothing.
    @Test("runs one at a time on a machine too small for even that")
    func tinyMachine() {
        #expect(Run.jobs(asked: nil, cores: 1, memoryBytes: 1 << 20) == 1)
    }

    /// And a number somebody typed still wins over both. They can see their machine.
    @Test("does what it was told, whatever the machine looks like")
    func askedStillWins() {
        #expect(Run.jobs(asked: 12, cores: 2, memoryBytes: 1 << 30) == 12)
    }
}
