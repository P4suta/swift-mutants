// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsRunner

/// The one place a subprocess is started.
///
/// A run starts processes from a dozen places - a version probe, two baselines, a compile
/// per module, the coverage pass, a validation build, a run per mutant - and a rule that
/// every one of them must remember to record would have a dozen chances to be broken
/// silently in exactly the run somebody is trying to diagnose. Recording here means a call
/// site cannot forget; the label is an enum, so it cannot even be spelled wrong.
///
/// These tests run `/bin/sh`, which costs a millisecond. They belong to the unit tier: what
/// makes an inner loop slow is a toolchain, not a process.
@Suite("Runner")
struct RunnerTests {

    /// The execution a recorded event describes, if it describes one.
    static func execution(of event: TraceEvent) -> TraceEvent.Execution? {
        if case .exec(let execution) = event.kind { return execution }
        return nil
    }

    static func shell(_ script: String, timeout: Duration? = nil) -> ProcessSpec {
        ProcessSpec(
            kind: .testFixture,
            executable: "/bin/sh",
            arguments: ["-c", script],
            directory: FileManager.default.temporaryDirectory.path,
            environment: ["SWIFT_MUTANTS_TEST_TOKEN": "0"],
            timeout: timeout
        )
    }

    @Test("runs a command and reports what it did")
    func runsACommand() async {
        let recorder = TraceRecorder(retaining: 16)
        let outcome = await Runner(recorder: recorder).run(Self.shell("printf hello; exit 3"))
        #expect(outcome.exitCode == 3)
        #expect(String(decoding: outcome.standardOutput, as: UTF8.self) == "hello")
        #expect(outcome.startFailure == nil)
        #expect(!outcome.timedOut)
    }

    /// Exactly one, so that counting `exec` events in a recording counts processes.
    @Test("records one event per call, and no more")
    func recordsExactlyOnce() async {
        let recorder = TraceRecorder(retaining: 16)
        let runner = Runner(recorder: recorder)
        _ = await runner.run(Self.shell("true"))
        _ = await runner.run(Self.shell("true"))

        let executions = recorder.retainedEvents().compactMap(Self.execution)
        #expect(executions.count == 2)
    }

    /// Names, never values. A diagnostics bundle is something people attach to a bug
    /// report, and a credential that reached a child would otherwise reach the report.
    @Test("records the names of the variables a child was given, and not their values")
    func recordsEnvironmentNamesOnly() async throws {
        let recorder = TraceRecorder(retaining: 16)
        let spec = ProcessSpec(
            kind: .testFixture,
            executable: "/bin/sh",
            arguments: ["-c", "true"],
            directory: FileManager.default.temporaryDirectory.path,
            environment: ["INNOCUOUS": "fine", "A_SECRET": "hunter2"],
            timeout: nil
        )
        _ = await Runner(recorder: recorder).run(spec)

        let execution = try #require(recorder.retainedEvents().compactMap(Self.execution).first)
        #expect(execution.environmentNames.sorted() == ["A_SECRET", "INNOCUOUS"])
        let line = String(decoding: try recorder.retainedEvents()[0].jsonLine(), as: UTF8.self)
        #expect(!line.contains("hunter2"))
    }

    /// A command that never became a process is precisely what a reader needs to be told
    /// about, so it is recorded with exit -1 and the refusal rather than dropped.
    @Test("records a command it could not start")
    func recordsACommandThatCouldNotStart() async throws {
        let recorder = TraceRecorder(retaining: 16)
        let spec = ProcessSpec(
            kind: .testFixture,
            executable: "/nonexistent/definitely-not-here",
            arguments: [],
            directory: FileManager.default.temporaryDirectory.path,
            environment: [:],
            timeout: nil
        )
        let outcome = await Runner(recorder: recorder).run(spec)
        #expect(outcome.exitCode == -1)
        #expect(outcome.startFailure != nil)

        let execution = try #require(recorder.retainedEvents().compactMap(Self.execution).first)
        #expect(execution.exitCode == -1)
        #expect(execution.failure != nil)
    }

    @Test("hands back the sequence its record was written at")
    func carriesItsTraceSequence() async {
        let recorder = TraceRecorder(retaining: 16)
        recorder.record(.phaseBegan(phase: "before"))
        let outcome = await Runner(recorder: recorder).run(Self.shell("true"))
        #expect(outcome.traceSequence == 2)
    }

    @Test("stops a command that overruns its deadline")
    func stopsAnOverrunningCommand() async {
        let recorder = TraceRecorder(retaining: 16)
        let outcome = await Runner(recorder: recorder).run(
            Self.shell("sleep 30", timeout: .milliseconds(200))
        )
        #expect(outcome.timedOut)
        #expect(outcome.exitCode != 0)
    }

    /// The stuck process is usually a grandchild: `swift test` starts `xctest`, which starts
    /// the binary under test. Killing only the immediate child leaves the tree running and
    /// the machine slowly filling up with them.
    ///
    /// Asked of the process table rather than of a clock. An earlier version gave a
    /// grandchild a second to write a file and checked three seconds later, so the margin
    /// had to cover *the deadline* being slow to fire rather than the grandchild being
    /// fast - and under a loaded machine it did not. Whether a process exists is not a
    /// question about timing.
    @Test("kills the whole tree, not only the process it started")
    func killsTheWholeTree() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-tree-kill-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: pidFile) }

        // The grandchild outlives its parent on purpose, and says who it is.
        let outcome = await Runner(recorder: TraceRecorder(retaining: 16)).run(
            Self.shell(
                """
                (while true; do sleep 0.2; done) & echo $! > '\(pidFile)'
                sleep 30
                """,
                timeout: .milliseconds(200)
            )
        )
        #expect(outcome.timedOut)

        let grandchild = try #require(
            Int32(
                try String(contentsOfFile: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)),
            "the fixture did not record a grandchild"
        )

        // A signal takes a moment to be delivered and reaped; existence does not take a
        // moment to be true. Polling asks the right question and bounds the wrong one.
        var alive = true
        for _ in 0..<50 where alive {
            alive = kill(grandchild, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(!alive, "a grandchild outlived the tree kill")
    }

    /// Output is retained for diagnosis, but a run that printed a gigabyte should not make
    /// the runner hold one. The record says how much there was either way.
    @Test("retains a bounded amount of what a command printed, and says how much there was")
    func boundsRetainedOutput() async throws {
        let recorder = TraceRecorder(retaining: 16)
        let runner = Runner(recorder: recorder, outputLimit: 64)
        let outcome = await runner.run(Self.shell("printf 'x%.0s' $(seq 1 5000)"))

        #expect(outcome.standardOutput.count == 64)
        let execution = try #require(recorder.retainedEvents().compactMap(Self.execution).first)
        #expect(execution.standardOutputBytes == 5000)
    }
}
