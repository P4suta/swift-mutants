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
package import SwiftMutantsTrace
import System

/// Supervises owned process trees and drains both output streams.
package struct Runner: Sendable {
    private let recorder: TraceRecorder
    package let outputLimit: Int

    package init(recorder: TraceRecorder, outputLimit: Int = 1 << 20) {
        self.recorder = recorder
        self.outputLimit = outputLimit
    }

    package func run(
        _ spec: ProcessSpec,
        matchingOutput: [String] = [],
        matchingLines: [OutputLinePattern] = []
    ) async -> ProcessOutcome {
        let start = ContinuousClock.now
        let deadline = Deadline()
        let monitor = ProcessMonitor(timeout: spec.timeout) { deadline.markExceeded() }
        defer { monitor.finish() }
        var options = PlatformOptions()
        options.processGroupID = 0
        let environment = spec.environment.sorted { $0.key < $1.key }
            .map { Array("\($0.key)=\($0.value)".utf8) }
        let configuration = Configuration(
            executable: .path(FilePath(spec.executable)),
            arguments: Arguments(spec.arguments),
            environment: .custom(environment),
            workingDirectory: FilePath(spec.directory),
            platformOptions: options
        )
        do {
            let collected = try await invoke(
                configuration, monitor: monitor, matching: matchingOutput, lines: matchingLines)
            let code: Int
            switch collected.terminationStatus {
            case .exited(let status): code = Int(status)
            case .signaled(let number): code = 128 + Int(number)
            }
            return finish(
                spec,
                code: code,
                streams: collected.closureResult,
                timedOut: deadline.wasExceeded,
                elapsed: ContinuousClock.now - start
            )
        } catch {
            return finish(
                spec,
                code: -1,
                streams: Streams(
                    output: BoundedBytes(limit: outputLimit),
                    errors: BoundedBytes(limit: outputLimit)
                ),
                timedOut: deadline.wasExceeded,
                elapsed: ContinuousClock.now - start,
                failure: String(describing: error)
            )
        }
    }

    private func invoke(
        _ configuration: Configuration,
        monitor: ProcessMonitor,
        matching: [String],
        lines: [OutputLinePattern]
    ) async throws -> ExecutionResult<Streams, SequenceOutput, SequenceOutput> {
        // Discover descendants before Swift Subprocess can tear down their parent.
        let task = Task {
            try await Subprocess.run(
                configuration,
                input: .none,
                output: .sequence,
                error: .sequence
            ) { execution in
                monitor.start(root: execution.processIdentifier.value)
                do { return try await collect(execution, matching: matching, lines: lines) } catch {
                    monitor.cancel()
                    throw error
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            monitor.cancel()
        }
    }

    private func collect(
        _ execution: Execution<NoInput, SequenceOutput, SequenceOutput>,
        matching: [String],
        lines: [OutputLinePattern]
    ) async throws -> Streams {
        async let output = Self.drain(
            execution.standardOutput, limit: outputLimit, matching: matching, lines: lines)
        async let errors = Self.drain(execution.standardError, limit: outputLimit, lines: lines)
        return Streams(output: try await output, errors: try await errors)
    }

    private func finish(
        _ spec: ProcessSpec,
        code: Int,
        streams: Streams,
        timedOut: Bool,
        elapsed: Duration,
        failure: String? = nil
    ) -> ProcessOutcome {
        let milliseconds =
            Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        let event = recorder.record(
            .exec(
                TraceEvent.Execution(
                    label: spec.kind.rawValue,
                    arguments: [spec.executable] + spec.arguments,
                    directory: spec.directory,
                    environmentNames: spec.environment.keys.sorted(),
                    timeoutMilliseconds: spec.timeout.map {
                        Int($0.components.seconds) * 1000
                            + Int($0.components.attoseconds / 1_000_000_000_000_000)
                    },
                    exitCode: code,
                    durationMilliseconds: milliseconds,
                    standardOutputDigest: streams.output.total == 0
                        ? nil : Digest.of(streams.output.retained),
                    standardOutputBytes: streams.output.total,
                    failure: failure ?? (timedOut ? "timed out" : nil)
                )
            )
        )
        return ProcessOutcome(
            exitCode: code,
            timedOut: timedOut,
            durationMilliseconds: milliseconds,
            standardOutput: streams.output.retained,
            standardOutputBytes: streams.output.total,
            standardError: streams.errors.retained,
            startFailure: failure,
            traceSequence: event.sequence,
            matchedOutput: streams.output.matches,
            standardErrorBytes: streams.errors.total,
            matchedLines: streams.output.lineMatches.union(streams.errors.lineMatches)
        )
    }

    private static func drain(
        _ stream: SubprocessOutputSequence,
        limit: Int,
        matching: [String] = [],
        lines: [OutputLinePattern] = []
    ) async throws -> BoundedBytes {
        var bytes = BoundedBytes(limit: limit, matching: matching, lines: lines)
        for try await chunk in stream {
            bytes.append(unsafe chunk.withUnsafeBytes { unsafe Array($0) })
        }
        return bytes
    }
}

private struct Streams: Sendable {
    let output: BoundedBytes
    let errors: BoundedBytes
}

struct BoundedBytes: Sendable {
    private(set) var retained: [UInt8] = []
    private(set) var total = 0
    let limit: Int
    private var matcher: OutputMatcher
    private var lineMatcher: OutputLines
    var matches: Set<String> { matcher.found }
    var lineMatches: Set<OutputLinePattern> { lineMatcher.found }

    init(limit: Int, matching: [String] = [], lines: [OutputLinePattern] = []) {
        self.limit = limit
        matcher = OutputMatcher(matching)
        lineMatcher = OutputLines(lines)
    }

    mutating func append(_ chunk: [UInt8]) {
        matcher.append(chunk)
        lineMatcher.append(chunk)
        total += chunk.count
        retained.append(contentsOf: chunk.prefix(max(0, limit - retained.count)))
    }
}

private final class Deadline: Sendable {
    private let exceeded = Mutex(false)
    var wasExceeded: Bool { exceeded.withLock { $0 } }
    func markExceeded() { exceeded.withLock { $0 = true } }
}
