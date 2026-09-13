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

    /// Prepares to run mutants `jobs` at a time.
    public init(
        plan: TestPlan,
        runner: Runner,
        scratch: URL,
        timeout: Duration? = .seconds(120),
        jobs: Int = 4
    ) {
        self.plan = plan
        self.runner = runner
        self.scratch = scratch
        self.timeout = timeout
        self.jobs = max(1, jobs)
    }

    /// Runs the instrumented baseline: the same tree, nothing awake.
    ///
    /// It has to pass. Every later answer is about the program in this tree, and if the
    /// tree with no mutant awake does not behave like the one the user wrote, every one of
    /// those answers is about a program nobody has.
    public func baseline() async -> Verdict {
        await trial(worker: 0).run(activating: nil)
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
        MutantResult(
            identity: mutant.identity,
            path: path,
            rule: mutant.rule,
            span: mutant.span,
            verdict: await trial(worker: worker).run(activating: mutant.index)
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
        return RunSummary(
            killed: counts[.killed] ?? 0,
            survived: counts[.survived] ?? 0,
            timedOut: counts[.timedOut] ?? 0,
            inconclusive: counts[.inconclusive] ?? 0,
            errored: counts[.errored] ?? 0,
            notRun: counts[.notRun] ?? 0,
            rejected: rejected,
            equivalent: counts[.equivalent] ?? 0,
            uncovered: 0,
            cached: 0,
            expectedSurvivors: 0
        )
    }
}
