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
    /// `stoppingAtFirstFailure` is true for a mutant, where the answer is known as soon as
    /// one test notices and every further second establishes something already
    /// established. It is false for the instrumented baseline, which is a diagnosis rather
    /// than a verdict: knowing that *a* test failed with nothing awake leaves somebody
    /// nowhere, and knowing which ones usually points straight at a test that asserts
    /// something about the source files rather than about the program.
    public func run(
        activating index: UInt32?,
        onlyTests: [String]? = nil,
        stoppingAtFirstFailure: Bool = true
    ) async -> Verdict {
        await run(
            waking: index.map { [$0] } ?? [],
            onlyTests: onlyTests,
            stoppingAtFirstFailure: stoppingAtFirstFailure
        )
    }

    /// Runs the tests with a set of mutants awake.
    ///
    /// Several at once only when no test reaches more than one of them, which is the
    /// caller's rule to keep. A test bundle costs what it costs to load whether one test
    /// runs or forty, so a package with good locality spends most of a run starting
    /// processes - and a batch is how that bill is divided.
    public func run(
        waking indices: [UInt32],
        onlyTests: [String]? = nil,
        stoppingAtFirstFailure: Bool = true
    ) async -> Verdict {
        let name = indices.isEmpty ? "base" : indices.map(String.init).joined(separator: "-")
        let stream = scratch.appending(path: "events-\(worker)-\(name)")
        let watcher = Mutex(StreamWatcher())

        // A pipe is what makes stopping early possible. When one cannot be made - a
        // filesystem that has no pipes, a path that cannot be written - the run falls back
        // to a plain file read afterwards. The answer is the same; only the cost is worse,
        // and a run that quietly produced no answer would be far worse than that.
        let pipe = EventPipe(path: stream.path)
        let outcome = await runner.run(
            spec(
                writingEventsTo: pipe?.path ?? stream.path,
                waking: indices,
                onlyTests: onlyTests
            ),
            watching: pipe
        ) { line in
            guard let event = TestEvent(line: line) else { return true }
            let keepGoing = watcher.withLock { $0.observe(event) }
            return stoppingAtFirstFailure ? keepGoing : true
        }
        pipe?.discard()

        if pipe == nil {
            for line in Self.lines(of: stream) {
                guard let event = TestEvent(line: line) else { continue }
                watcher.withLock { _ = $0.observe(event) }
            }
            try? FileManager.default.removeItem(at: stream)
        }
        return watcher.withLock {
            $0.verdict(
                after: Self.termination(of: outcome),
                taking: outcome.durationMilliseconds
            )
        }
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
    private func spec(
        writingEventsTo path: String, waking indices: [UInt32], onlyTests: [String]?
    ) -> ProcessSpec {
        var environment = plan.environment
        environment["SWIFT_MUTANTS"] = "1"
        environment["SWIFT_MUTANTS_TEST_TOKEN"] = "\(worker)"
        if !indices.isEmpty {
            environment["SWIFT_MUTANTS_ACTIVE"] =
                indices.map(String.init).joined(separator: ",")
        }

        // One `--filter` per test rather than one alternation, so no identifier has to
        // survive being spliced into a bigger pattern. Absent means the whole suite, which
        // is what a run without coverage has to do.
        let selection = (onlyTests ?? []).flatMap { ["--filter", Prober.exactly($0)] }

        return ProcessSpec(
            kind: indices.isEmpty ? .baseline : .mutant,
            executable: plan.executable,
            arguments: plan.arguments + [
                "--event-stream-output-path", path,
                "--event-stream-version", plan.eventStreamVersion,
                "--no-parallel",
            ] + selection,
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
