// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsExecute
import Testing

@testable import SwiftMutantsReport

/// What a reader can ask about a mutant that ran out of time.
///
/// A confirmed timeout counts as a detection, and on a real package it can be a fifth of
/// them: measured on a project using this tool, 84 of 399 detections in a 52.85% score,
/// every one of them retried and none of them changed by the retry. Whether those are
/// mutants that stopped a program terminating or trials that never got the processor is
/// the difference between a finding and a gap in the measurement, and the reader of the
/// report is the person who has to tell them apart.
///
/// The tool already knows. `Verdict` carries the processor time the trial used, and
/// `Termination` says whether the kernel stopped it for working or a clock stopped it for
/// waiting - a distinction the scheduler relies on when it decides what to retry. Both
/// were dropped where the report is built, so the reader saw identical rows.
@Suite("Evidence about a mutant that ran out of time")
struct TimeoutEvidenceTests {

    static func report(_ verdict: Verdict) -> RunReport {
        RunReport(
            of: RunReportTests.Fixture.outcome(
                results: [RunReportTests.Fixture.result(verdict: verdict)]),
            positions: RunReportTests.Fixture.positions
        )
    }

    static func verdict(_ termination: Termination, cpu: Int?) -> Verdict {
        Verdict(
            outcome: .timedOut,
            killedBy: [],
            firstFailure: nil,
            startedTests: ["ExampleTests/works()"],
            durationMilliseconds: 30_000,
            cpuMilliseconds: cpu,
            termination: termination
        )
    }

    /// The number that separates the two. A trial stopped after thirty seconds of wall
    /// clock having used four hundred milliseconds of processor did not run a program that
    /// would not stop - it waited.
    @Test("says how much processor a mutant's trial used")
    func carriesProcessorTime() {
        let row = Self.report(Self.verdict(.timedOut, cpu: 412)).mutants.first
        #expect(row?.cpuMilliseconds.value == 412)
    }

    /// Nothing measured is not zero measured. A run whose trials could not account for
    /// themselves must not report that they did no work.
    @Test("says nothing rather than zero when no processor time was measured")
    func saysNothingWhenUnmeasured() {
        let row = Self.report(Self.verdict(.timedOut, cpu: nil)).mutants.first
        #expect(row?.cpuMilliseconds.value == nil)
    }

    /// Which limit stopped it, in the report rather than only inside the trial. An
    /// allowance is a fact about the program and the same on any machine; a deadline may be
    /// a fact about the machine. The outcome is `timed-out` either way, so without this the
    /// two are one row.
    @Test("says which limit stopped it")
    func namesTheLimit() {
        #expect(
            Self.report(Self.verdict(.overranWork, cpu: 30_000)).mutants.first?
                .stoppedBy.value == "processor-allowance")
        #expect(
            Self.report(Self.verdict(.timedOut, cpu: 412)).mutants.first?
                .stoppedBy.value == "deadline")
    }

    /// And nothing at all for a mutant no limit stopped, which is most of them.
    @Test("says nothing about a limit for a mutant no limit stopped")
    func silentWhenNoLimitFired() {
        let verdict = Verdict(
            outcome: .killed,
            killedBy: ["ExampleTests/works()"],
            firstFailure: "expected 3",
            startedTests: ["ExampleTests/works()"],
            durationMilliseconds: 12,
            cpuMilliseconds: 9,
            termination: .exited(1)
        )
        let row = Self.report(verdict).mutants.first
        #expect(row?.stoppedBy.value == nil)
        #expect(row?.cpuMilliseconds.value == 9)
    }
}
