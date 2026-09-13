// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import Synchronization
public import SwiftMutantsBuild
public import SwiftMutantsRunner

/// One run of the tests, with at most one mutant awake.
///
/// The unit the whole run is made of. A trial starts the built tests with one mutant
/// activated, watches what they say, and stops them the moment one of them notices - so a
/// mutant costs the time until something catches it rather than the time the suite takes.
public struct Trial: Sendable {

    private let plan: TestPlan
    private let runner: Runner
    private let scratch: URL
    private let timeout: Duration?
    private let worker: Int

    /// Prepares to run one mutant at a time inside `scratch`.
    ///
    /// `worker` is handed to the tests as `SWIFT_MUTANTS_TEST_TOKEN`, so a suite that is
    /// not hermetic - one that wants a database or a temporary directory of its own - has
    /// something to key on. Nothing forces a suite to use it, but a suite that cannot run
    /// beside itself has no other way to be told which copy it is.
    public init(
        plan: TestPlan,
        runner: Runner,
        scratch: URL,
        timeout: Duration? = .seconds(120),
        worker: Int = 0
    ) {
        self.plan = plan
        self.runner = runner
        self.scratch = scratch
        self.timeout = timeout
        self.worker = worker
    }

    /// Runs the tests with one mutant awake, or with none at all.
    ///
    /// `nil` is the instrumented baseline: the same tree, the same process, nothing
    /// activated. It has to pass, and a run whose instrumented baseline fails is a run
    /// whose every later answer would be about a program the user did not write.
    public func run(activating index: UInt32?) async -> Verdict {
        let stream = scratch.appending(path: "events-\(worker)-\(index.map(String.init) ?? "base")")
        let watcher = Mutex(StreamWatcher())

        // A pipe is what makes stopping early possible. When one cannot be made - a
        // filesystem that has no pipes, a path that cannot be written - the run falls back
        // to a plain file read afterwards. The answer is the same; only the cost is worse,
        // and a run that quietly produced no answer would be far worse than that.
        let pipe = EventPipe(path: stream.path)
        let outcome = await runner.run(
            spec(writingEventsTo: pipe?.path ?? stream.path, activating: index),
            watching: pipe
        ) { line in
            guard let event = TestEvent(line: line) else { return true }
            return watcher.withLock { $0.observe(event) }
        }
        pipe?.discard()

        if pipe == nil {
            for line in Self.lines(of: stream) {
                guard let event = TestEvent(line: line) else { continue }
                watcher.withLock { _ = $0.observe(event) }
            }
            try? FileManager.default.removeItem(at: stream)
        }
        return watcher.withLock { $0.verdict(after: Self.termination(of: outcome)) }
    }

    /// What to start, and what to tell it.
    ///
    /// Three arguments are added here rather than left to whoever built the plan, because
    /// all three are requirements of *watching* a run rather than of running one:
    ///
    /// - where to write its events, which only this knows, since the pipe is per trial;
    /// - which spelling of the stream to use, pinned rather than left to a default;
    /// - `--no-parallel`, because swift-testing runs tests concurrently by default and
    ///   "which test killed this mutant" is then a race. Measured on the pinned toolchain:
    ///   four tests, three overlapping pairs by default and none with the flag.
    private func spec(writingEventsTo path: String, activating index: UInt32?) -> ProcessSpec {
        var environment = plan.environment
        environment["SWIFT_MUTANTS"] = "1"
        environment["SWIFT_MUTANTS_TEST_TOKEN"] = "\(worker)"
        if let index { environment["SWIFT_MUTANTS_ACTIVE"] = "\(index)" }

        return ProcessSpec(
            kind: index == nil ? .baseline : .mutant,
            executable: plan.executable,
            arguments: plan.arguments + [
                "--event-stream-output-path", path,
                "--event-stream-version", plan.eventStreamVersion,
                "--no-parallel",
            ],
            directory: plan.directory,
            environment: environment,
            timeout: timeout
        )
    }

    private static func termination(of outcome: ProcessOutcome) -> Termination {
        if let failure = outcome.startFailure { return .couldNotStart(failure) }
        if outcome.timedOut { return .timedOut }
        if outcome.stoppedEarly { return .stopped }
        return .exited(outcome.exitCode)
    }

    private static func lines(of file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
