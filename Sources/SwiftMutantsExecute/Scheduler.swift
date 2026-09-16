// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import SwiftMutantsBuild
import SwiftMutantsCore
public import SwiftMutantsInstrument
public import SwiftMutantsRunner

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

    /// What runs the tests, one per worker.
    ///
    /// A function rather than a value, because a worker's host is a worker's: the token a
    /// non-hermetic suite keys on, and on the Xcode path a derived-data directory, are per
    /// worker and two workers sharing either would be two workers treading on each other.
    private let host: @Sendable (Int, Budget) -> any MutantHost
    private let jobs: Int
    let coverage: Coverage?

    /// How long a mutant gets, given how much of the suite it faces.
    let budget: Budget

    /// How many test bundles there are, for a mutant that faces all of them.
    let bundleCount: Int

    /// Prepares to run mutants `jobs` at a time, through whatever starts the tests.
    ///
    /// With `coverage`, a mutant is offered only the tests that reach it, and a mutant no
    /// test reaches is answered without starting anything. Without it, every mutant is
    /// offered the whole suite, because any test might be the one that notices.
    public init(
        host: @escaping @Sendable (Int, Budget) -> any MutantHost,
        jobs: Int = 4,
        coverage: Coverage? = nil,
        budget: Budget = .flat(.seconds(120)),
        bundleCount: Int = 1
    ) {
        self.host = host
        self.jobs = max(1, jobs)
        self.coverage = coverage
        self.budget = budget
        self.bundleCount = max(1, bundleCount)
    }

    /// The same, for the SwiftPM path: one ``Trial`` per worker, from one built plan.
    ///
    /// Kept as an initialiser of its own because it is what almost every caller wants, and
    /// because a caller writing the closure out would be a caller who could get the worker
    /// token wrong.
    public init(
        bundles: TestBundles,
        runner: Runner,
        scratch: URL,
        timeout: Duration? = .seconds(120),
        jobs: Int = 4,
        coverage: Coverage? = nil,
        budget: Budget? = nil
    ) {
        self.init(
            host: { worker, budget in
                Trial(
                    bundles: bundles,
                    runner: runner,
                    scratch: scratch,
                    budget: budget,
                    worker: worker
                )
            },
            jobs: jobs,
            coverage: coverage,
            budget: budget ?? timeout.map(Budget.flat) ?? .flat(.seconds(120)),
            bundleCount: bundles.plans.count
        )
    }

    /// The same scheduler, now knowing which tests reach which mutants.
    public func offering(_ coverage: Coverage?) -> Self {
        Self(
            host: host,
            jobs: jobs,
            coverage: coverage,
            budget: budget,
            bundleCount: bundleCount
        )
    }

    /// The same scheduler, now knowing what a mutant's share of the suite is worth.
    ///
    /// Apart from ``offering(_:)`` because the two are learned at the same moment and from
    /// the same phase, and folding them into one call would hide that either can be absent.
    public func budgeting(_ budget: Budget) -> Self {
        Self(
            host: host,
            jobs: jobs,
            coverage: coverage,
            budget: budget,
            bundleCount: bundleCount
        )
    }

    /// How many processes a catalogue will take, before any of them start.
    ///
    /// The saving, countable in advance: a mutant nothing reaches takes none, and mutants
    /// no test shares take one between them - one *per test bundle they span*, because a
    /// package builds one bundle per test target. Counting units rather than processes was
    /// right while a package built one bundle, and afterwards understated every run in the
    /// flattering direction.
    public func processes(for mutants: [InstrumentedMutant]) -> Int {
        units(for: mutants).reduce(0) {
            $0 + $1.processes(using: coverage, ofTotal: bundleCount)
        }
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
        await trial(worker: 0).run(activating: nil, settling: .wholeSuite)
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
                        .run(activating: nil, settling: .wholeSuite)
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
        progress: @Sendable (MutantResult) -> Void = { _ in }
    ) async -> [MutantResult] {
        let first = await attempt(mutants, progress: progress)
        return await retryingTimeouts(first, of: mutants, progress: progress)
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
        progress: @Sendable (MutantResult) -> Void
    ) async -> [MutantResult] {
        let byIdentity = Dictionary(
            mutants.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        var settled: [MutantResult] = []
        settled.reserveCapacity(results.count)

        for result in results {
            // Not one the kernel stopped for its work. That is a fact about the program
            // and the same on any machine, so a second look on a quiet one would establish
            // nothing that is not already established - and would cost the allowance again.
            guard result.verdict.outcome == .timedOut,
                result.verdict.termination != .overranWork,
                let mutant = byIdentity[result.identity]
            else {
                settled.append(result)
                continue
            }
            var again = await self.result(of: mutant, worker: 0)
            again = MutantResult(
                identity: again.identity,
                path: again.path,
                rule: again.rule,
                span: again.span,
                original: again.original,
                replacement: again.replacement,
                verdict: again.verdict,
                attempts: result.attempts + again.attempts,
                index: again.index
            )
            settled.append(again)
            progress(again)
        }
        return settled
    }

    /// One pass over the mutants, `jobs` at a time.
    ///
    /// A unit of work is a batch, which is usually several mutants: a test bundle costs
    /// what it costs to load whether one test runs or forty, so a package with good
    /// locality spends most of a run starting processes. Mutants whose covering tests are
    /// disjoint share one, and a batch that cannot be shared out - it crashed, it ran out
    /// of time, a test failed that belongs to nobody - is asked again one at a time.
    private func attempt(
        _ mutants: [InstrumentedMutant],
        progress: @Sendable (MutantResult) -> Void
    ) async -> [MutantResult] {
        guard !mutants.isEmpty else { return [] }
        let units = self.units(for: mutants)

        // Through the pool, which is where the rule that two live workers never share a
        // token is written down. A token names a worker's scratch directory, its derived
        // data and the fixtures a non-hermetic suite keys on, and this loop used to derive
        // it from the position of the unit - so two workers shared a directory on
        // essentially every run.
        let answered = await WorkerPool(jobs: jobs).run(over: units) { [self] unit, token in
            await answers(for: unit, worker: token)
        } asEachFinishes: { _, answers in
            for answer in answers { progress(answer) }
        }

        // Back into catalogue order. Which worker finished first is a fact about the
        // machine, and a batch reorders things further; a report that changed shape
        // because of either could not be diffed against yesterday's.
        let order = Dictionary(
            uniqueKeysWithValues: mutants.enumerated().map { ($1.identity, $0) })
        return answered.flatMap { $0 }.sorted {
            (order[$0.identity] ?? 0) < (order[$1.identity] ?? 0)
        }
    }

    func result(of mutant: InstrumentedMutant, worker: Int) async -> MutantResult {
        // A mutant nothing reaches cannot be caught, and running the suite to find that
        // out would be spending the most expensive thing this tool does on a question
        // already answered. It is reported as surviving, which it does, and as uncovered,
        // which is the part somebody can act on - usually more cheaply than by writing an
        // assertion.
        var covering: [String]?
        if let coverage {
            guard let reached = coverage.tests(reaching: mutant.index), !reached.isEmpty else {
                return Self.unreached(mutant)
            }
            covering = reached
        }

        return MutantResult(
            identity: mutant.identity,
            path: mutant.path,
            rule: mutant.rule,
            span: mutant.span,
            original: mutant.original,
            replacement: mutant.replacement,
            verdict: await trial(worker: worker)
                .run(activating: mutant.index, onlyTests: covering),
            attempts: 1,
            index: mutant.index
        )
    }

    /// The answer for a mutant no test reaches, arrived at without starting a process.
    private static func unreached(_ mutant: InstrumentedMutant) -> MutantResult {
        MutantResult(
            identity: mutant.identity,
            path: mutant.path,
            rule: mutant.rule,
            span: mutant.span,
            original: mutant.original,
            replacement: mutant.replacement,
            verdict: Verdict(
                outcome: .survived,
                killedBy: [],
                firstFailure: nil,
                startedTests: [],
                durationMilliseconds: 0,
                termination: .exited(0)
            ),
            // Nothing was attempted, and the count says so rather than claiming a run.
            attempts: 0,
            index: mutant.index
        )
    }

    func trial(worker: Int) -> any MutantHost { host(worker, budget) }
}
