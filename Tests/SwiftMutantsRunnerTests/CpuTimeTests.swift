// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsRunner

/// Measuring and bounding a child in the unit it actually works in.
///
/// A wall-clock deadline is the only limit this tool had, and it makes every verdict
/// sensitive to something that is not a property of the program: a mutant that met its
/// deadline because somebody started a build in another window is recorded as a detection.
/// The measurement was simply in the wrong unit.
///
/// CPU time is the right one. A process doing the same work consumes the same user and
/// system seconds whether it is alone on the machine or sharing it with seventeen others -
/// the scheduler gives it fewer per wall second, not fewer in total. So a limit in CPU
/// seconds is a limit on the *work* a mutant does, which is a fact about the program.
///
/// It is not a perfect invariant and this repository does not claim one: a throttled core
/// or one of Apple silicon's efficiency cores does less per CPU second than a performance
/// core. Those vary far less than contention does, and they vary the same way for the
/// baseline this is derived from as for the trials it bounds.
///
/// Enforced by the kernel rather than by watching a clock. `RLIMIT_CPU` sends `SIGXCPU`
/// the moment a process passes its allowance, with nothing polling and nothing to get
/// wrong. Measured directly: a spinning child dies at 1.005 seconds of CPU under a
/// one-second limit, and a child that only sleeps is untouched by it - which is why the
/// wall clock stays as the backstop it should always have been, for the one thing a CPU
/// limit cannot see.
@Suite("What a child cost, and what it was allowed")
struct CpuTimeTests {

    static func runner() -> Runner { Runner(recorder: TraceRecorder()) }

    static func spec(
        _ script: String, cpu: Duration? = nil, timeout: Duration? = .seconds(60)
    ) -> ProcessSpec {
        ProcessSpec(
            kind: .mutant,
            executable: "/bin/sh",
            arguments: ["-c", script],
            directory: "/tmp",
            environment: [:],
            timeout: timeout,
            cpuLimit: cpu
        )
    }

    /// The measurement, which is the half that lets a budget be written in this unit at all.
    @Test("says how much processor a child used")
    func measuresCpu() async {
        let outcome = await Self.runner().run(
            Self.spec("i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done", cpu: .seconds(30)))
        #expect(outcome.exitCode == 0)
        #expect((outcome.cpuMilliseconds ?? 0) > 0, "\(outcome.cpuMilliseconds as Any)")
    }

    /// A child that waits costs nothing, which is the whole distinction: waiting is not
    /// working, and a mutant that waits is not the mutant a CPU limit is looking for.
    @Test("charges a child nothing for waiting")
    func sleepingIsFree() async {
        let outcome = await Self.runner().run(Self.spec("sleep 1", cpu: .seconds(30)))
        #expect(outcome.exitCode == 0)
        #expect((outcome.cpuMilliseconds ?? 999) < 200, "\(outcome.cpuMilliseconds as Any)")
    }

    /// And the enforcement. A process past its allowance is stopped by the kernel, whatever
    /// else is happening on the machine.
    @Test("stops a child that spends more processor than it was allowed")
    func stopsASpinner() async {
        let outcome = await Self.runner().run(
            Self.spec("while :; do :; done", cpu: .seconds(1), timeout: .seconds(120)))
        #expect(outcome.exitCode != 0)
        #expect(outcome.overranCpu, "exit \(outcome.exitCode)")
        // Not the wall clock. The point is that nothing was waiting on one.
        #expect(!outcome.timedOut)
    }

    /// A child that waits out its allowance is not stopped by it, so the wall clock is
    /// still the only thing that can see a deadlock.
    @Test("leaves a child that waits longer than its processor allowance alone")
    func sleepingPastTheLimit() async {
        let outcome = await Self.runner().run(
            Self.spec("sleep 2", cpu: .seconds(1), timeout: .seconds(60)))
        #expect(outcome.exitCode == 0)
        #expect(!outcome.overranCpu)
    }

    /// Nothing changes for a command that was given no allowance - which is every build,
    /// every probe, everything that is not a mutant under measurement.
    @Test("leaves a command with no allowance exactly as it was")
    func noLimitNoWrapper() async {
        let outcome = await Self.runner().run(Self.spec("echo hello", cpu: nil))
        #expect(outcome.exitCode == 0)
        #expect(outcome.standardOutputText.trimmingCharacters(in: .newlines) == "hello")
        #expect(outcome.cpuMilliseconds == nil)
    }

    /// The accounting must not reach the caller. A trial's standard error is read for what
    /// the tests said, and a line this tool added to measure with would be a line somebody
    /// has to explain.
    @Test("keeps its own accounting out of what the child said")
    func accountingIsInvisible() async {
        let outcome = await Self.runner().run(
            Self.spec("echo said something >&2", cpu: .seconds(30)))
        let said = String(decoding: outcome.standardError, as: UTF8.self)
        #expect(said.contains("said something"))
        #expect(!said.contains("0m0."), "the accounting leaked into the child's output: \(said)")
    }
}
