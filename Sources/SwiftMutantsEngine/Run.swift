// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsBuild
import SwiftMutantsDiscover
import SwiftMutantsSnapshot

public import Foundation
import SwiftMutantsValidate

public import SwiftMutantsConfig
import SwiftMutantsCache
import SwiftMutantsCore
public import SwiftMutantsExecute
import SwiftMutantsInstrument
public import SwiftMutantsRunner

/// The whole pipeline, from a package on disk to an answer about its tests.
///
/// Ordered the way it is because each step earns the right to the next. Nothing is built
/// until the compiler has said which mutants exist; nothing is run until the tree with
/// nothing awake behaves like the one the user wrote; and no score is reported about a tree
/// whose mutants could not be shown to be in it.
public struct Run: Sendable {

    let root: URL
    let configuration: Configuration
    let runner: Runner
    let executable: String
    let workspace: URL
    let testArguments: [String]
    let changedSince: String?

    /// Prepares a run of the package at `root`, working inside `workspace`.
    ///
    /// `testArguments` are handed to the test bundle verbatim, before the ones this tool
    /// adds to watch it. They are never parsed: a tool that interpreted them would be
    /// guessing at somebody's test runner, and guessing wrong is a mutant reported as
    /// surviving tests that were never run. They are also a scope - narrowing the suite
    /// narrows what a score is about, and the report says what was passed.
    public init(
        root: URL,
        configuration: Configuration,
        runner: Runner,
        workspace: URL,
        executable: String = "/usr/bin/swift",
        testArguments: [String] = [],
        changedSince reference: String? = nil
    ) {
        self.root = root
        self.configuration = configuration
        self.runner = runner
        self.executable = executable
        self.workspace = workspace
        self.testArguments = testArguments
        self.changedSince = reference
    }

    /// Carries out the run.
    ///
    /// The workspace the user pointed at is only ever read. Everything below happens inside
    /// a copy, which is what makes it safe to point this at a repository somebody is in the
    /// middle of working in.
    public func run(
        environment: [String: String] = [:],
        progress: @Sendable (RunStage) -> Void = { _ in }
    ) async throws(RunError) -> RunOutcome {
        let tree = try snapshot(progress)

        progress(.discovering)
        let (listing, scope) = try await catalogue(environment: environment, progress: progress)

        let subjects = try subjectsToValidate(listing, in: tree)
        let built = try await prime(tree, environment: environment, progress: progress)

        progress(
            .instrumenting(
                files: subjects.count, mutants: listing.catalog.mutants.count))

        let validated = try await validate(
            subjects, in: tree, using: built, environment: environment, progress: progress)

        progress(.proving)
        try prove(validated.files.map(\.instrumented))

        progress(.building)
        let plan = try await buildTests(in: tree, environment: environment)

        let pipes = try pipesDirectory()
        let calibration = try await calibrate(
            plan, in: pipes, environment: environment, progress: progress)
        let baseline = calibration.baseline
        let measured = await ask(
            Work(validated: validated, subjects: subjects),
            calibration,
            at: Site(tree: tree, pipes: pipes, plan: built, environment: environment),
            listing: listing,
            progress: progress
        )

        let (summary, expectations) = try account(
            measured, rejecting: validated.rejected.count, about: scope)
        return RunOutcome(
            results: measured.results,
            rejected: validated.rejected,
            summary: summary,
            baseline: baseline,
            contendedBaseline: calibration.contended,
            filesInstrumented: validated.files.count,
            scope: scope,
            positions: listing.positions,
            digests: listing.digests,
            expectations: expectations,
            unanchored: listing.unanchored.map(\.mutant),
            plan: plan,
            shard: configuration.execution.shard
        )
    }

    /// Reads the package and narrows what was found to what the run was asked about.
    private func catalogue(
        environment: [String: String],
        progress: @Sendable (RunStage) -> Void
    ) async throws(RunError) -> (Listing, RunScope) {
        let everything = try await list(environment: environment)
        let (listing, scope) = try await narrow(
            everything, environment: environment, progress: progress)
        guard !listing.catalog.mutants.isEmpty else {
            throw RunError(
                """
                nothing to mutate in \(root.path). `swift-mutants list --explain` says what \
                was passed over and why.
                """
            )
        }
        return (listing, scope)
    }

    /// Narrows the catalogue to what changed, when a run asked for that.
    ///
    /// A whole-package run is `Θ(mutants)` however clever the scheduling, and on a package
    /// of any size that is not something anybody puts in a pre-push hook. A run scoped to
    /// the files somebody just touched is `Θ(mutants in those files)`.
    ///
    /// Preferred over caching verdicts across runs, and for soundness rather than effort:
    /// a mutant's verdict depends on which tests reach it, and which tests reach it can
    /// change because some *other* file changed. A cache key honest about that has to
    /// include the whole tree. A scope makes no claim about what it did not run, and the
    /// report says what it was about.
    private func narrow(
        _ listing: Listing,
        environment: [String: String],
        progress: @Sendable (RunStage) -> Void
    ) async throws(RunError) -> (Listing, RunScope) {
        guard let reference = changedSince else { return (listing, .everything) }

        let changed = try await ChangedFiles(root: root, runner: runner)
            .since(reference, environment: environment)
        let narrowed = listing.keeping { changed.contains($0) }
        progress(
            .scoped(since: reference, files: narrowed.filesWithMutants.count))
        return (narrowed, .changed(since: reference, files: narrowed.filesWithMutants.count))
    }

    /// Measures the suite with nothing awake, then works out what one mutant may cost.
    ///
    /// In that order, because the second comes from the first. The baseline gets a
    /// generous budget of its own: it is spent once, and the alternative is giving up on a
    /// package whose tests are simply long.
    private func calibrate(
        _ plan: TestPlan,
        in pipes: URL,
        environment: [String: String],
        progress: @Sendable (RunStage) -> Void
    ) async throws(RunError) -> Calibration {
        let jobs = configuration.execution.jobs ?? 4
        let calibrating = Scheduler(
            plan: plan,
            runner: runner,
            scratch: pipes,
            timeout: configuration.test.timeout ?? Self.calibrationBudget,
            jobs: jobs
        )
        progress(.baseline)
        let baseline = try await provedBaseline(
            calibrating, environment: environment, progress: progress)

        // Measured the way the mutants will be run, because that is the only figure a
        // deadline can be derived from. It also asks whether this suite can run beside
        // itself at all, which a mutation run assumes and nothing else checks.
        let crowd = jobs > 1 ? await calibrating.contendedBaseline() : [baseline]
        if let unhappy = crowd.first(where: { $0.outcome != .survived }) {
            throw RunError(
                """
                the tests pass alone and do not pass with \(jobs) copies of them running at \
                once, which is how a run runs them. A suite that shares a port, a directory \
                or a temporary file with itself does this. Try `--jobs 1`.
                \(Self.blame(unhappy))
                """
            )
        }
        let slowest = crowd.max { $0.durationMilliseconds < $1.durationMilliseconds } ?? baseline
        let budget = configuration.test.timeout ?? Self.budget(from: slowest, jobs: jobs)
        progress(.calibrated(budget))
        return Calibration(
            baseline: baseline,
            contended: slowest,
            scheduler: Scheduler(
                plan: plan, runner: runner, scratch: pipes, timeout: budget, jobs: jobs),
            plan: plan,
            jobs: jobs
        )
    }

    /// What measuring the suite established, and what it lets the rest of the run do.
    struct Calibration {
        let baseline: Verdict
        let contended: Verdict
        let scheduler: Scheduler
        let plan: TestPlan
        let jobs: Int
    }

    /// Asks each test what it reaches.
    ///
    /// One process per test, which sounds expensive and is not: a launch costs about what
    /// a handful of tests cost, and running *one* test is cheap even when running all of
    /// them is not. The phase is `Θ(tests)` and it replaces a per-mutant term of
    /// `Θ(tests)` with `Θ(the tests that matter)` - six hundred mutants against four
    /// hundred tests goes from a quarter of a million test executions to a few thousand.
    func cover(
        _ calibration: Calibration,
        probing tests: [String],
        in pipes: URL,
        against known: Known,
        progress: @Sendable (RunStage) -> Void
    ) async -> Coverage? {
        let (catalogue, listing) = (known.catalogue, known.listing)
        let indices = Array(catalogue.files.keys)
        guard !tests.isEmpty else { return nil }
        progress(.probing(tests: tests.count))

        // What did not move does not have to be asked again.
        let observable = Array(Set(catalogue.files.values))
        let memory = recalled(observable, listing)
            .reader(observable: observable, digests: listing.digests)
        let byIdentity = Dictionary(
            catalogue.identities.map { ($0.value.digest, $0.key) },
            uniquingKeysWith: { first, _ in first })

        var remembered: [String: Set<UInt32>] = [:]
        var toAsk: [String] = []
        for test in tests {
            guard let reach = memory.reach(of: test) else {
                toAsk.append(test)
                continue
            }
            remembered[test] = Set(reach.compactMap { byIdentity[$0] })
        }
        if !remembered.isEmpty {
            progress(.recalled(known: remembered.count, total: tests.count))
        }

        let asked =
            toAsk.isEmpty
            ? nil
            : await Prober(
                plan: calibration.plan,
                runner: runner,
                scratch: pipes,
                timeout: configuration.test.timeout ?? Self.calibrationBudget,
                jobs: calibration.jobs
            ).probe(toAsk)
        let coverage = Self.merged(remembered: remembered, asked: asked, tests: tests)
        remember(coverage, observable: observable, catalogue: catalogue, listing: listing)

        let covered = indices.compactMap { coverage.tests(reaching: $0)?.count }
        let average =
            covered.isEmpty ? 0 : Double(covered.reduce(0, +)) / Double(covered.count)
        progress(
            .covered(uncovered: coverage.uncovered(among: indices), averageTests: average))
        if !coverage.untrusted.isEmpty {
            progress(.unmeasured(tests: coverage.untrusted.count))
        }
        return coverage
    }

    /// Runs the instrumented tree with nothing awake, and insists that it passes.
    ///
    /// This is what earns the right to report anything at all. If the tree with no mutant
    /// awake does not behave like the one the user wrote, every later answer is about a
    /// program nobody has - and would read as a score about theirs.
    /// Which tests said so, and what they said.
    ///
    /// Named, because "the baseline failed" is a sentence somebody can do nothing with.
    /// The usual cause is a test that asserts something about the source files rather than
    /// about the program - a lint gate, a golden file, a check on imports - and
    /// instrumentation changes those files by design. Knowing which test it was turns a
    /// dead end into a one-line exclusion.
    static func blame(_ baseline: Verdict) -> String {
        guard !baseline.killedBy.isEmpty else {
            return """

                It named no failing test, so look at what it did instead: \
                \(baseline.testsStarted) tests started and it ended \(baseline.termination).
                """
        }
        let named = baseline.killedBy.prefix(5).map { "  \($0)" }.joined(separator: "\n")
        let more =
            baseline.killedBy.count > 5
            ? "\n  ... and \(baseline.killedBy.count - 5) more" : ""
        let said = baseline.firstFailure.map { "\n\nThe first said: \($0)" } ?? ""
        return """

            These tests failed with nothing awake:
            \(named)\(more)\(said)

            A test that asserts something about your source files rather than about your \
            program will fail here, because instrumentation changes those files by design. \
            Exclude it with `-- --skip <name>` if that is what this is.
            """
    }

    /// Runs every mutant of every file, in catalogue order.
    /// How long the baseline itself is given, before anything is known about the suite.
    ///
    /// Generous, because it is spent once and the alternative is a run that gives up on a
    /// package whose tests are simply long.
    public static let calibrationBudget: Duration = .seconds(1800)

    /// How long one mutant gets, derived from how long the suite takes when nothing is
    /// wrong with it.
    ///
    /// Five times the baseline, and never less than thirty seconds. A number picked out of
    /// the air is either so tight that a loaded machine reports a working suite as a hang,
    /// or so loose that a mutant which really does hang costs the whole budget - and the
    /// only thing that tells the two apart is how long this suite takes.
    ///
    /// Five, and not five times the number of workers, because the baseline it is derived
    /// from was already measured with every worker running - so the contention is in the
    /// number rather than guessed at on top of it. Guessing on top of it made a genuine
    /// hang cost sixteen minutes; guessing under it, from a solitary suite, timed out most
    /// of a run. Measured here: thirty-five seconds alone, over five times that with eight
    /// at once.
    ///
    /// The asymmetry still sets the direction. A deadline met under load costs one serial
    /// retry; a deadline set too tight *without* a retry reports a survivor as a kill,
    /// which is the mistake nobody ever finds out about.
    public static func budget(from baseline: Verdict, jobs: Int) -> Duration {
        _ = jobs
        let solitary = max(baseline.durationMilliseconds, 1)
        return max(.seconds(30), .milliseconds(solitary * 5))
    }

    /// Where the instrumented copy is built.
    ///
    /// Inside the copy, where the package expects to be built, rather than off to one
    /// side. A test that reaches for something the build produced - a helper executable, a
    /// generated resource, a fixture binary - looks in `.build` relative to its package,
    /// and a build placed anywhere else leaves it looking at nothing. Measured on this
    /// repository: twelve tests failed with nothing awake because the scripted toolchain
    /// they drive was built somewhere they do not look.
    ///
    /// Nothing is polluted by this. The copy is disposable and the tree the user pointed
    /// at is never written to at all.
    static func buildDirectory(in tree: URL) -> URL {
        tree.appending(path: ".build")
    }
}
