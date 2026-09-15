// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import Synchronization
import SwiftMutantsCore
public import SwiftMutantsBuild
public import SwiftMutantsRunner

/// One run of the tests, with at most one mutant awake.
///
/// The unit the whole run is made of. A trial starts the built tests with one mutant
/// activated, watches what they say, and stops them the moment one of them notices - so a
/// mutant costs the time until something catches it rather than the time the suite takes.
public struct Trial: MutantHost {

    private let bundles: TestBundles
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
        bundles: TestBundles,
        runner: Runner,
        scratch: URL,
        timeout: Duration? = .seconds(120),
        worker: Int = 0
    ) {
        self.bundles = bundles
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
    /// Runs the tests with a set of mutants awake.
    ///
    /// Several at once only when no test reaches more than one of them, which is the
    /// caller's rule to keep. A test bundle costs what it costs to load whether one test
    /// runs or forty, so a package with good locality spends most of a run starting
    /// processes - and a batch is how that bill is divided.
    public func run(
        waking indices: [UInt32],
        onlyTests: [String]?,
        settling: StreamWatcher.Settlement
    ) async -> Verdict {
        // Only the bundles that could catch it. A package builds one per test target, and
        // offering a mutant all of them would be paying for a process per target to
        // establish what the probe already said: that no test in there goes near it.
        let wanted = bundles.covering(onlyTests)
        var said: [Verdict] = []
        for plan in wanted {
            let verdict = await run(
                plan, waking: indices, onlyTests: onlyTests, settling: settling)
            said.append(verdict)
            // A kill is a claim about one test, so the first bundle to make it has made
            // it; survival is a claim about all of them, so it needs all of them. The
            // baseline asks for the whole suite and keeps going either way, because it is
            // a diagnosis rather than a verdict.
            if verdict.outcome == .killed, settling == .oneMutant { break }
        }
        return Verdict.across(said)
    }

    /// One bundle, watched to whichever end `settling` asks for.
    private func run(
        _ plan: TestPlan,
        waking indices: [UInt32],
        onlyTests: [String]?,
        settling: StreamWatcher.Settlement
    ) async -> Verdict {
        let mutants = indices.isEmpty ? "base" : indices.map(String.init).joined(separator: "-")
        let name = "\(plan.module.isEmpty ? "tests" : plan.module)-\(mutants)"
        let stream = scratch.appending(path: "events-\(worker)-\(name)")
        let watcher = Mutex(StreamWatcher(settling: settling))

        // A pipe is what makes stopping early possible. When one cannot be made - a
        // filesystem that has no pipes, a path that cannot be written - the run falls back
        // to a plain file read afterwards. The answer is the same; only the cost is worse,
        // and a run that quietly produced no answer would be far worse than that.
        let pipe = EventPipe(path: stream.path)
        let outcome = await runner.run(
            Launch(plan: plan, worker: worker, timeout: timeout).specification(
                writingEventsTo: pipe?.path ?? stream.path,
                waking: indices,
                // Only this bundle's share of them. A filter naming a test that is not in
                // here matches nothing, and swift-testing treats a filter that matches
                // nothing as a run of no tests - which reads exactly like a mutant nothing
                // noticed.
                onlyTests: Self.share(of: onlyTests, in: plan)
            ),
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
        return watcher.withLock {
            $0.verdict(
                after: Self.termination(of: outcome),
                taking: outcome.durationMilliseconds
            )
        }
    }

    /// The tests of `onlyTests` that live in this bundle, or nothing to mean all of them.
    static func share(of tests: [String]?, in plan: TestPlan) -> [String]? {
        guard let tests, !plan.module.isEmpty else { return tests }
        let mine = tests.filter { TestBundles.module(of: $0) == plan.module }
        return mine.isEmpty ? tests : mine
    }

    /// How this trial starts a mutant. ``Launch`` is where the command is decided.
    ///
    /// The first bundle, for the callers that want to show somebody a command to paste.
    /// A mutant may face several, and `explain` names the one that caught it.
    var launch: Launch? {
        bundles.plans.first.map { Launch(plan: $0, worker: worker, timeout: timeout) }
    }

    func specification(
        writingEventsTo path: String, waking indices: [UInt32], onlyTests: [String]?
    ) -> ProcessSpec? {
        launch?.specification(writingEventsTo: path, waking: indices, onlyTests: onlyTests)
    }

    /// Runs one test with nothing awake, telling the runtime where to write what it
    /// reached.
    ///
    /// No event stream and no early stop: the whole point is to let the test finish, since
    /// what it reached is only complete when it has. The answer is in the log rather than
    /// in anything this reads, so all this says is whether the process got that far.
    ///
    /// The probe runs with nothing awake, so the suite passes and the process exits zero.
    /// Anything else is a process that did not get to the end of its job, and whatever it
    /// managed to write is a prefix rather than an answer.
    public func probe(_ test: String, writingTo log: URL) async -> Bool {
        // The one bundle it lives in. Asking every bundle to run a test only one of them
        // has would be one process per target to establish that the other targets do not
        // contain it.
        guard let plan = bundles.holding(test) ?? bundles.plans.first else { return false }
        var environment = plan.environment
        environment["SWIFT_MUTANTS"] = "1"
        environment["SWIFT_MUTANTS_TEST_TOKEN"] = "\(worker)"
        environment[Prober.probeVariable] = log.path

        let outcome = await runner.run(
            ProcessSpec(
                kind: .probe,
                executable: plan.executable,
                arguments: plan.arguments + [
                    "--no-parallel", "--filter", Prober.exactly(test),
                ],
                directory: plan.directory,
                environment: environment,
                timeout: timeout
            )
        )
        return outcome.exitCode == 0
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
