// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

import Subprocess
import Synchronization
import SwiftMutantsCore
public import SwiftMutantsTrace
import System

/// Starts one process, watches it, and writes down what happened.
///
/// This is the only place in the engine that starts a subprocess, and that is the point. A
/// run starts them from a dozen places - a version probe, two baselines, a compile per
/// module, the coverage pass, a validation build, a run per mutant - and a rule that every
/// one of them must remember to record would have a dozen chances to be broken silently, in
/// exactly the run somebody is trying to diagnose. Recorded here, a call site can forget
/// nothing: the label is a closed enum, and the record is written whether the command
/// succeeded, failed, or never started at all.
public struct Runner: Sendable {

    private let recorder: TraceRecorder

    /// How many bytes of each stream are kept.
    ///
    /// The whole output of a failed build is what makes a failure diagnosable, and the whole
    /// output of a runaway test is what makes a machine run out of memory. The head is kept
    /// and the total is counted, so the record is honest about what it is not holding.
    public let outputLimit: Int

    /// Creates a runner that records into `recorder`.
    public init(recorder: TraceRecorder, outputLimit: Int = 1 << 20) {
        self.recorder = recorder
        self.outputLimit = outputLimit
    }

    /// Runs a command to completion, to its deadline, or to the point where it turns out it
    /// cannot be started.
    ///
    /// Never throws. A command that could not be started is an outcome with exit `-1` and a
    /// reason, because a command that never became a process is precisely what a reader of
    /// the account needs to be told about, and an error thrown past the recorder would be a
    /// command nobody wrote down.
    public func run(_ spec: ProcessSpec) async -> ProcessOutcome {
        let started = ContinuousClock.now
        let timedOut = Deadline()

        do {
            let collected = try await Subprocess.run(
                Configuration(
                    executable: .path(FilePath(spec.executable)),
                    arguments: Arguments(spec.arguments),
                    environment: .custom(Self.environmentBlock(spec.environment)),
                    workingDirectory: FilePath(spec.directory),
                    platformOptions: Self.ownProcessGroup()
                ),
                input: .none,
                output: .sequence,
                error: .sequence
            ) { execution in
                try await Self.superviseLoop(
                    execution: execution,
                    timeout: spec.timeout,
                    limit: outputLimit,
                    timedOut: timedOut
                )
            }

            let elapsed = Self.milliseconds(since: started)
            let status = Self.status(of: collected.terminationStatus)
            return finish(
                spec,
                Completion(
                    exitCode: status.code,
                    signal: status.signal,
                    timedOut: timedOut.wasExceeded,
                    duration: elapsed,
                    output: collected.closureResult.standardOutput,
                    error: collected.closureResult.standardError,
                    startFailure: nil
                )
            )
        } catch {
            return finish(
                spec,
                Completion(
                    exitCode: -1,
                    signal: nil,
                    timedOut: timedOut.wasExceeded,
                    duration: Self.milliseconds(since: started),
                    output: BoundedBytes(limit: outputLimit),
                    error: BoundedBytes(limit: outputLimit),
                    startFailure: String(describing: error)
                )
            )
        }
    }

    /// Drains both streams while a deadline watches the process group.
    ///
    /// The two drains end when the process does, because its streams close; the deadline is
    /// cancelled at that point. Draining concurrently is not an optimisation - a child that
    /// fills a pipe nobody is reading blocks forever, which is the failure that makes
    /// `Foundation.Process` a poor foundation for this.
    private static func superviseLoop(
        execution: Execution<NoInput, SequenceOutput, SequenceOutput>,
        timeout: Duration?,
        limit: Int,
        timedOut: Deadline
    ) async throws -> Streams {
        let identifier = execution.processIdentifier.value

        let deadline = timeout.map { budget in
            Task {
                try? await Task.sleep(for: budget)
                guard !Task.isCancelled else { return }
                timedOut.markExceeded()
                await Self.killTree(identifier)
            }
        }
        defer { deadline?.cancel() }

        async let output = Self.drain(execution.standardOutput, limit: limit)
        async let errors = Self.drain(execution.standardError, limit: limit)
        return Streams(standardOutput: try await output, standardError: try await errors)
    }

    /// Ends the whole tree the command started, not only the command.
    ///
    /// The stuck process is usually a grandchild: `swift test` starts `xctest`, which starts
    /// the binary under test. The child was spawned as its own process group leader, so its
    /// group id is its pid and a negative signal reaches every descendant. Politely first,
    /// then not.
    private static func killTree(_ identifier: pid_t) async {
        kill(-identifier, SIGTERM)
        try? await Task.sleep(for: .milliseconds(200))
        kill(-identifier, SIGKILL)
    }

    /// Reads a stream, keeping the head and counting the whole.
    private static func drain(
        _ stream: SubprocessOutputSequence,
        limit: Int
    ) async throws -> BoundedBytes {
        var bounded = BoundedBytes(limit: limit)
        for try await chunk in stream {
            // The buffer's only safe accessor is a raw span; copying it out is the unsafe
            // step, and -strict-memory-safety wants that said rather than hidden.
            bounded.append(unsafe chunk.withUnsafeBytes { unsafe Array($0) })
        }
        return bounded
    }

    /// Writes the record and assembles the outcome.
    ///
    /// One record per call, always, at the one place that can see everything about the
    /// command: what it was, what it was given, and what became of it.
    /// Everything known about a command once it is over.
    private struct Completion {
        let exitCode: Int
        let signal: Int?
        let timedOut: Bool
        let duration: Int
        let output: BoundedBytes
        let error: BoundedBytes
        let startFailure: String?
    }

    /// Writes the record and assembles the outcome.
    ///
    /// One record per call, always, at the one place that can see everything about the
    /// command: what it was, what it was given, and what became of it.
    private func finish(_ spec: ProcessSpec, _ completion: Completion) -> ProcessOutcome {
        let output = completion.output
        let event = recorder.record(
            .exec(
                TraceEvent.Execution(
                    label: spec.kind.rawValue,
                    arguments: [spec.executable] + spec.arguments,
                    directory: spec.directory,
                    environmentNames: spec.environment.keys.sorted(),
                    timeoutMilliseconds: spec.timeout.map(Self.milliseconds),
                    exitCode: completion.exitCode,
                    durationMilliseconds: completion.duration,
                    standardOutputDigest: output.total == 0 ? nil : Digest.of(output.retained),
                    standardOutputBytes: output.total,
                    failure: completion.startFailure ?? (completion.timedOut ? "timed out" : nil)
                )
            )
        )

        return ProcessOutcome(
            exitCode: completion.exitCode,
            signal: completion.signal,
            timedOut: completion.timedOut,
            durationMilliseconds: completion.duration,
            standardOutput: output.retained,
            standardError: completion.error.retained,
            standardOutputBytes: output.total,
            standardErrorBytes: completion.error.total,
            startFailure: completion.startFailure,
            traceSequence: event.sequence
        )
    }

    private static func status(of termination: TerminationStatus) -> (code: Int, signal: Int?) {
        switch termination {
        case .exited(let code): (Int(code), nil)
        case .signaled(let signal): (128 + Int(signal), Int(signal))
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        milliseconds(ContinuousClock.now - start)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    /// Renders an environment as the `KEY=VALUE` block a spawn takes.
    ///
    /// Sorted, so that two runs of the same command compose the same block and a recording
    /// of one can be compared with a recording of the other.
    private static func environmentBlock(_ environment: [String: String]) -> [[UInt8]] {
        environment
            .sorted { $0.key < $1.key }
            .map { Array("\($0.key)=\($0.value)".utf8) }
    }

    /// Spawns the child as its own process group leader, so that ending the group ends
    /// every descendant and no signal of ours ever reaches this process.
    private static func ownProcessGroup() -> PlatformOptions {
        var options = PlatformOptions()
        options.processGroupID = 0
        return options
    }

    private struct Streams: Sendable {
        let standardOutput: BoundedBytes
        let standardError: BoundedBytes
    }
}

/// A stream's head, and how long the whole stream was.
struct BoundedBytes: Sendable {
    /// The bytes kept.
    private(set) var retained: [UInt8] = []

    /// How many there were altogether.
    private(set) var total = 0

    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append(_ chunk: some Sequence<UInt8>) {
        for byte in chunk {
            total += 1
            if retained.count < limit {
                retained.append(byte)
            }
        }
    }
}

/// Whether a command outlived its deadline.
///
/// A reference rather than a value because the watcher that sets it and the caller that
/// reads it are in different tasks, and `Mutex` is noncopyable so it cannot travel between
/// them on its own.
final class Deadline: Sendable {
    private let exceeded = Mutex(false)

    /// Whether the deadline passed before the command finished.
    var wasExceeded: Bool { exceeded.withLock { $0 } }

    /// Records that the deadline passed.
    func markExceeded() { exceeded.withLock { $0 = true } }
}
