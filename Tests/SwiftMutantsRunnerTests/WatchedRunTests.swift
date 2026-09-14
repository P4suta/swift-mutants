// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Synchronization
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsRunner

/// Stopping a process the moment its answer is known.
///
/// The claim that makes a mutation run affordable: a mutant costs the time until some test
/// notices it, not the time the whole suite takes. These put that to a real process tree -
/// a shell that writes a line, then a line that decides it, then sleeps for far longer than
/// any test should - and check that the sleep never happens.
@Suite("Watched runs")
struct WatchedRunTests {

    static func pipePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-watch-\(UUID().uuidString)").path
    }

    static func spec(_ script: String, timeout: Duration? = .seconds(30)) -> ProcessSpec {
        ProcessSpec(
            kind: .testFixture,
            executable: "/bin/sh",
            arguments: ["-c", script],
            directory: FileManager.default.temporaryDirectory.path,
            environment: [:],
            timeout: timeout
        )
    }

    /// The whole point. The script would take thirty seconds; the watcher ends it at the
    /// second line.
    @Test("ends the process as soon as the watcher has its answer")
    func stopsEarly() async throws {
        let pipe = try #require(EventPipe(path: Self.pipePath()))
        defer { pipe.discard() }
        let seen = Mutex<[String]>([])

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("echo one > '\(pipe.path)'; echo stop > '\(pipe.path)'; sleep 30"),
            watching: pipe
        ) { line in
            seen.withLock { $0.append(line) }
            return line != "stop"
        }

        #expect(seen.withLock { $0 } == ["one", "stop"])
        #expect(outcome.stoppedEarly)
        #expect(!outcome.timedOut)
    }

    /// A process nobody stops runs to the end, and the watcher sees everything it wrote.
    @Test("lets a process finish when nothing decides")
    func runsToCompletion() async throws {
        let pipe = try #require(EventPipe(path: Self.pipePath()))
        defer { pipe.discard() }
        let seen = Mutex<[String]>([])

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("printf 'a\\nb\\nc\\n' > '\(pipe.path)'"),
            watching: pipe
        ) { line in
            // Deliberately slow. The process writes everything and exits at once, so
            // without waiting for the reader to finish, the last lines would be lost -
            // and lost lines are a mutant reported as surviving tests that caught it.
            Thread.sleep(forTimeInterval: 0.05)
            seen.withLock { $0.append(line) }
            return true
        }

        #expect(seen.withLock { $0 } == ["a", "b", "c"])
        #expect(outcome.exitCode == 0)
        #expect(!outcome.stoppedEarly)
    }

    /// A process that writes nothing at all must not leave the run waiting for a line that
    /// is never coming. This is the case a crashed test binary produces.
    @Test("ends when the process does, even if it wrote nothing")
    func silentProcess() async throws {
        let pipe = try #require(EventPipe(path: Self.pipePath()))
        defer { pipe.discard() }

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("exit 3"), watching: pipe
        ) { _ in true }

        #expect(outcome.exitCode == 3)
        #expect(!outcome.stoppedEarly)
    }

    /// A deadline and an answer both end with a signal, so they have to be told apart:
    /// one means nothing was learned in the time allowed and the other means everything
    /// was.
    @Test("keeps a deadline apart from an answer")
    func timeoutIsNotAnAnswer() async throws {
        let pipe = try #require(EventPipe(path: Self.pipePath()))
        defer { pipe.discard() }

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("sleep 30", timeout: .milliseconds(300)), watching: pipe
        ) { _ in true }

        #expect(outcome.timedOut)
        #expect(!outcome.stoppedEarly)
    }

    /// The test binary is a grandchild of the command, so ending the command is not
    /// enough - the thing still holding the machine is the one further down.
    ///
    /// Asked of the process table rather than of a clock. An earlier version gave a
    /// grandchild a few seconds to write a file and checked afterwards, which meant the
    /// margin had to cover *the reader* being slow rather than the grandchild being fast -
    /// and under a loaded machine it did not. Whether a process exists is not a question
    /// about timing.
    @Test("ends the whole tree, not just the command it started")
    func killsTheTree() async throws {
        let pipe = try #require(EventPipe(path: Self.pipePath()))
        defer { pipe.discard() }
        let pidFile = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-pid-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: pidFile) }

        _ = await Runner(recorder: TraceRecorder()).run(
            Self.spec(
                """
                (while true; do sleep 0.2; done) & echo $! > '\(pidFile)'
                echo stop > '\(pipe.path)'
                sleep 30
                """),
            watching: pipe
        ) { line in line != "stop" }

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
        #expect(!alive, "a grandchild outlived the kill")
    }

    /// The reader ends for two different reasons and only one of them is a decision: the
    /// handler saying stop, and the child going away. Reading the second as the first marks
    /// an ordinary completion as "stopped", which downstream is a mutant nobody learned
    /// anything about - a survivor quietly reclassified as a harness failure.
    ///
    /// Slow on purpose: the handler is still working when the process exits, so the reader
    /// certainly outlives the child rather than only usually.
    @Test("does not mistake the child going away for an answer")
    func childEndingIsNotAnAnswer() async throws {
        let pipe = try #require(EventPipe(path: Self.pipePath()))
        defer { pipe.discard() }

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("printf 'a\\nb\\nc\\n' > '\(pipe.path)'"),
            watching: pipe
        ) { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return true
        }

        #expect(outcome.exitCode == 0)
        #expect(!outcome.stoppedEarly)
    }

    /// Watching is optional, and a run without it behaves exactly as it did before.
    @Test("runs unwatched when there is nothing to watch")
    func unwatched() async throws {
        let outcome = await Runner(recorder: TraceRecorder()).run(Self.spec("exit 7"))
        #expect(outcome.exitCode == 7)
        #expect(!outcome.stoppedEarly)
    }
}
