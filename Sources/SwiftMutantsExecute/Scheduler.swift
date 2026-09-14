// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import SwiftMutantsBuild
public import SwiftMutantsCore
public import SwiftMutantsInstrument
public import SwiftMutantsRunner

/// What became of one mutant.
public struct MutantResult: Sendable, Hashable {

    /// Which mutant.
    public let identity: MutantIdentity

    /// Where it is in the file the user wrote.
    public let path: WorkspaceRelativePath

    /// Which rule produced it.
    public let rule: RuleIdentifier

    /// Where in that file.
    public let span: SourceSpan

    /// What the tests said about it.
    public let verdict: Verdict

    /// How many times it had to be run.
    ///
    /// More than once means the first attempt ran out of time and was tried again on a
    /// quiet machine. That is worth seeing: a deadline met under load says nothing about
    /// a mutant, and a report that hid the retry would look like an answer it is not.
    public let attempts: Int
}

/// Runs every mutant, a bounded number at a time.
///
/// Mutants run in parallel and the tests inside one mutant run in series, which is the only
/// arrangement that gives a stable answer to "which test caught this". Turning it around -
/// one mutant at a time with its tests in parallel - would make that a race, and coverage
/// attribution built on a race is a different answer every run.
///
/// Every worker uses the same built bundle. There is only ever one build: the mutants all
/// live in it behind their own guards, and which one is awake is a matter of one
/// environment variable. So a worker needs nothing of its own but a pipe to watch and a
/// token to tell a non-hermetic suite which copy it is.
public struct Scheduler: Sendable {

    private let plan: TestPlan
    private let runner: Runner
    private let scratch: URL
    private let timeout: Duration?
    private let jobs: Int
    private let coverage: Coverage?

    /// Prepares to run mutants `jobs` at a time.
    ///
    /// With `coverage`, a mutant is offered only the tests that reach it, and a mutant no
    /// test reaches is answered without starting anything. Without it, every mutant is
    /// offered the whole suite, because any test might be the one that notices.
    public init(
        plan: TestPlan,
        runner: Runner,
        scratch: URL,
        timeout: Duration? = .seconds(120),
        jobs: Int = 4,
        coverage: Coverage? = nil
    ) {
        self.plan = plan
        self.runner = runner
        self.scratch = scratch
        self.timeout = timeout
        self.jobs = max(1, jobs)
        self.coverage = coverage
    }

    /// The same scheduler, now knowing which tests reach which mutants.
    public func offering(_ coverage: Coverage?) -> Self {
        Self(
            plan: plan,
            runner: runner,
            scratch: scratch,
            timeout: timeout,
            jobs: jobs,
            coverage: coverage
        )
    }

    /// Runs the instrumented baseline: the same tree, nothing awake.
    ///
    /// It has to pass. Every later answer is about the program in this tree, and if the
    /// tree with no mutant awake does not behave like the one the user wrote, every one of
    /// those answers is about a program nobody has.
    public func baseline() async -> Verdict {
        // Run to the end rather than stopping at the first failure. A baseline is a
        // diagnosis, not a verdict: "a test failed with nothing awake" leaves somebody
        // nowhere, and the list of which ones usually points straight at the cause.
        await trial(worker: 0).run(activating: nil, stoppingAtFirstFailure: false)
    }

    /// Runs the baseline the way the mutants will be run: all workers at once.
    ///
    /// Two questions at once, and a run depends on both answers.
    ///
    /// Can this suite run beside itself? A mutation run starts `jobs` copies of it against
    /// one machine, and a suite that shares a port, a fixture directory or a temporary
    /// file with itself fails for reasons that have nothing to do with any mutant. Better
    /// to find that out here, where the tool can say so, than to have it appear as a
    /// scattering of unexplained kills.
    ///
    /// And how long does it take *like this*? A deadline derived from one suite on an idle
    /// machine is the wrong number: measured on this repository, a solitary run took
    /// thirty-five seconds and eight concurrent ones took more than five times that, so a
    /// budget of five times the solitary figure timed out most of the run. The contended
    /// figure is the one the mutants will live under, so it is the one to measure.
    ///
    /// Returns the slowest of them, which is the one a deadline has to cover.
    public func contendedBaseline() async -> [Verdict] {
        await withTaskGroup(of: Verdict.self) { group in
            for worker in 0..<jobs {
                group.addTask { [self] in
                    await trial(worker: worker)
                        .run(activating: nil, stoppingAtFirstFailure: false)
                }
            }
            var verdicts: [Verdict] = []
            for await verdict in group { verdicts.append(verdict) }
            return verdicts
        }
    }

    /// Runs every mutant, reporting them in the order they were given.
    ///
    /// Order is restored rather than observed: which worker finishes first is a fact about
    /// the machine, and a report that changed shape because a machine was busy could not be
    /// diffed against yesterday's.
    ///
    /// `progress` is called once per mutant as its answer arrives, from whichever worker
    /// had it. It is for showing somebody that something is happening, so it is given the
    /// result rather than a count.
    public func run(
        _ mutants: [InstrumentedMutant],
        in path: WorkspaceRelativePath,
        progress: @Sendable (MutantResult) -> Void = { _ in }
    ) async -> [MutantResult] {
        let first = await attempt(mutants, in: path, progress: progress)
        return await retryingTimeouts(first, of: mutants, in: path, progress: progress)
    }

    /// Runs the mutants that ran out of time again, one at a time, on a quiet machine.
    ///
    /// The reason this exists is not hypothetical. A killed mutant stops at the first test
    /// that notices it; a surviving mutant runs the whole suite. So the mutants that meet
    /// a deadline are, overwhelmingly, the survivors - and counting a deadline as a
    /// detection turns every one of them into a kill. Measured on this repository: 592
    /// mutants, 82 deadlines, 0 survivors reported, and a score of 100%, which was not
    /// true of anything.
    ///
    /// Serially, because the deadline was met while eight test processes shared a machine
    /// and the retry is the observation that is actually about the mutant. A mutant that
    /// runs out of time twice, the second time alone, has earned the verdict.
    private func retryingTimeouts(
        _ results: [MutantResult],
        of mutants: [InstrumentedMutant],
        in path: WorkspaceRelativePath,
        progress: @Sendable (MutantResult) -> Void
    ) async -> [MutantResult] {
        let byIdentity = Dictionary(
            mutants.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        var settled: [MutantResult] = []
        settled.reserveCapacity(results.count)

        for result in results {
            guard result.verdict.outcome == .timedOut,
                let mutant = byIdentity[result.identity]
            else {
                settled.append(result)
                continue
            }
            var again = await self.result(of: mutant, in: path, worker: 0)
            again = MutantResult(
                identity: again.identity,
                path: again.path,
                rule: again.rule,
                span: again.span,
                verdict: again.verdict,
                attempts: result.attempts + again.attempts
            )
            settled.append(again)
            progress(again)
        }
        return settled
    }

    /// One pass over the mutants, `jobs` at a time.
    private func attempt(
        _ mutants: [InstrumentedMutant],
        in path: WorkspaceRelativePath,
        progress: @Sendable (MutantResult) -> Void
    ) async -> [MutantResult] {
        guard !mutants.isEmpty else { return [] }
        var finished = [MutantResult?](repeating: nil, count: mutants.count)

        await withTaskGroup(of: (Int, MutantResult).self) { group in
            var next = 0
            // One task per worker to begin with, and one more started for each that
            // finishes. The alternative - every mutant as a task at once - would have the
            // task group holding a task per mutant, and on a package of any size that is a
            // lot of nothing waiting to start.
            while next < min(jobs, mutants.count) {
                let position = next
                group.addTask { [self] in
                    (
                        position,
                        await result(of: mutants[position], in: path, worker: position % jobs)
                    )
                }
                next += 1
            }
            while let (position, result) = await group.next() {
                finished[position] = result
                progress(result)
                guard next < mutants.count else { continue }
                let position = next
                group.addTask { [self] in
                    (
                        position,
                        await self.result(of: mutants[position], in: path, worker: position % jobs)
                    )
                }
                next += 1
            }
        }
        return finished.compactMap { $0 }
    }

    private func result(
        of mutant: InstrumentedMutant, in path: WorkspaceRelativePath, worker: Int
    ) async -> MutantResult {
        // A mutant nothing reaches cannot be caught, and running the suite to find that
        // out would be spending the most expensive thing this tool does on a question
        // already answered. It is reported as surviving, which it does, and as uncovered,
        // which is the part somebody can act on - usually more cheaply than by writing an
        // assertion.
        var covering: [String]?
        if let coverage {
            guard let reached = coverage.tests(reaching: mutant.index), !reached.isEmpty else {
                return Self.unreached(mutant, in: path)
            }
            covering = reached
        }

        return MutantResult(
            identity: mutant.identity,
            path: path,
            rule: mutant.rule,
            span: mutant.span,
            verdict: await trial(worker: worker)
                .run(activating: mutant.index, onlyTests: covering),
            attempts: 1
        )
    }

    /// The answer for a mutant no test reaches, arrived at without starting a process.
    private static func unreached(
        _ mutant: InstrumentedMutant, in path: WorkspaceRelativePath
    ) -> MutantResult {
        MutantResult(
            identity: mutant.identity,
            path: path,
            rule: mutant.rule,
            span: mutant.span,
            verdict: Verdict(
                outcome: .survived,
                killedBy: [],
                firstFailure: nil,
                startedTests: [],
                durationMilliseconds: 0,
                termination: .exited(0)
            ),
            // Nothing was attempted, and the count says so rather than claiming a run.
            attempts: 0
        )
    }

    private func trial(worker: Int) -> Trial {
        Trial(plan: plan, runner: runner, scratch: scratch, timeout: timeout, worker: worker)
    }
}

extension RunSummary {

    /// Counts up what a run found.
    ///
    /// `rejected` is passed in rather than counted from the results, because a rejected
    /// mutant never ran: the compiler refused it before there was anything to run. Counting
    /// only what executed would quietly drop it from the report.
    public static func of(_ results: [MutantResult], rejected: Int = 0) -> RunSummary? {
        var counts: [Outcome: Int] = [:]
        for result in results { counts[result.verdict.outcome, default: 0] += 1 }

        // A survivor no test reaches is a different piece of news from a survivor the
        // tests looked at and did not notice. The first is usually the cheaper thing to
        // fix - often by deleting the code rather than by writing an assertion - and it is
        // the one a reader should see first.
        let uncovered = results.count {
            $0.verdict.outcome == .survived && $0.verdict.startedTests.isEmpty
        }
        return RunSummary(
            killed: counts[.killed] ?? 0,
            survived: counts[.survived] ?? 0,
            timedOut: counts[.timedOut] ?? 0,
            inconclusive: counts[.inconclusive] ?? 0,
            errored: counts[.errored] ?? 0,
            notRun: counts[.notRun] ?? 0,
            rejected: rejected,
            equivalent: counts[.equivalent] ?? 0,
            uncovered: uncovered,
            cached: 0,
            expectedSurvivors: 0
        )
    }
}
