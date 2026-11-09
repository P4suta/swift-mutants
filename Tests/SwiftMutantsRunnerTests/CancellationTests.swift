// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsRunner

@Suite("Process lifetime")
struct CancellationTests {
    @Test("the deadline remains active after both output streams close")
    func closedStreams() async {
        let result = await Runner(recorder: TraceRecorder()).run(
            RunnerTests.shell(
                "exec >/dev/null 2>&1; sleep 2",
                timeout: .milliseconds(100)
            )
        )
        #expect(result.timedOut)
        #expect(result.exitCode != 0)
    }

    @Test("cancellation stops and reaps the command and its descendant")
    func cancellation() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(
            path: "swift-mutants-cancel-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            await Runner(recorder: TraceRecorder()).run(
                ProcessSpec(
                    kind: .testFixture,
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "set -m; sleep 60 & child=$!; printf '%s %s' $$ $child > '\(marker.path)'; wait",
                    ],
                    directory: marker.deletingLastPathComponent().path,
                    environment: [:],
                    timeout: .seconds(10)
                )
            )
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pids = try String(contentsOf: marker, encoding: .utf8).split(separator: " ").compactMap
        { Int32($0) }
        #expect(pids.count == 2)
        #expect(pids.count < 2 || getpgid(pids[0]) != getpgid(pids[1]))
        let rescue = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            for pid in pids { kill(pid, SIGKILL) }
            Issue.record("Cancellation left a descendant in a separate process group")
        }
        defer { rescue.cancel() }
        task.cancel()
        _ = await task.value
        for pid in pids {
            let deadline = ContinuousClock.now + .seconds(5)
            while kill(pid, 0) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(kill(pid, 0) == -1)
        }
    }
}
