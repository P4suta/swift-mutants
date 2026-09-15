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
        let bundles = try await buildTests(in: tree, environment: environment)

        let pipes = try pipesDirectory()
        let calibration = try await calibrate(
            bundles, in: pipes, environment: environment, progress: progress)
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
            plan: bundles.plans.first,
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
        _ bundles: TestBundles,
        in pipes: URL,
        environment: [String: String],
        progress: @Sendable (RunStage) -> Void
    ) async throws(RunError) -> Calibration {
        let jobs = configuration.execution.jobs ?? 4
        let calibrating = Scheduler(
            bundles: bundles,
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
        // Not announced here. What a mutant gets depends on how much of the suite reaches
        // it, and nothing knows that until the probe has run - so the line that says how
        // long each mutant is given is printed there rather than guessed at now.
        return Calibration(
            baseline: baseline,
            contended: slowest,
            scheduler: Scheduler(
                bundles: bundles,
                runner: runner,
                scratch: pipes,
                jobs: jobs,
                budget: Self.budget(
                    from: slowest, cheapestTrial: nil, asked: configuration.test.timeout)
            ),
            bundles: bundles,
            jobs: jobs,
            asked: configuration.test.timeout
        )
    }

    /// What measuring the suite established, and what it lets the rest of the run do.
    struct Calibration {
        let baseline: Verdict
        let contended: Verdict
        let scheduler: Scheduler
        let bundles: TestBundles
        let jobs: Int

        /// What somebody asked for with `--timeout`, if they asked.
        let asked: Duration?

        /// The deadline, once the probe has said what a near-empty trial costs.
        func budget(withCheapestTrial cheapest: Int?) -> Budget {
            Run.budget(from: contended, cheapestTrial: cheapest, asked: asked)
        }
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
    ) async -> Probed? {
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
                bundles: calibration.bundles,
                runner: runner,
                scratch: pipes,
                timeout: configuration.test.timeout ?? Self.calibrationBudget,
                jobs: calibration.jobs
            ).probe(toAsk)
        let coverage = Self.merged(
            remembered: remembered, asked: asked?.coverage, tests: tests)
        remember(coverage, observable: observable, catalogue: catalogue, listing: listing)

        let covered = indices.compactMap { coverage.tests(reaching: $0)?.count }
        let average =
            covered.isEmpty ? 0 : Double(covered.reduce(0, +)) / Double(covered.count)
        progress(
            .covered(uncovered: coverage.uncovered(among: indices), averageTests: average))
        if !coverage.untrusted.isEmpty {
            progress(.unmeasured(tests: coverage.untrusted.count))
        }
        return Probed(
            coverage: coverage, cheapestMilliseconds: asked?.cheapestMilliseconds)
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

    /// How long one mutant gets, once the run knows how much of the suite it faces.
    ///
    /// This was one number for every mutant - five times the whole contended suite, floor
    /// of thirty seconds - and coverage was not consulted at all. Coverage is this tool's
    /// largest saving and it was being spent in one direction only: a mutant reached by
    /// forty-five of a package's 1333 tests ran forty-five tests and was then given the
    /// budget of all 1333. Reported from a real package: 898 seconds for a trial that
    /// runs 3.4% of the suite.
    ///
    /// ``Budget`` carries the shape and the reasoning; this supplies the measurements.
    /// The suite's cost is the *contended* baseline, because that is the figure the
    /// mutants will live under - measured here, thirty-five seconds alone and over five
    /// times that with eight at once. The intercept is the cheapest thing the probe phase
    /// saw, which is a trial that ran one test, on this machine, under this contention.
    ///
    /// The asymmetry still sets the direction. A deadline met under load costs one serial
    /// retry; a deadline set too tight reports a survivor as a detection, which is the
    /// mistake nobody ever finds out about.
    public static func budget(
        from baseline: Verdict, cheapestTrial: Int?, asked: Duration?
    ) -> Budget {
        if let asked { return .flat(asked) }
        return Budget.deriving(
            suiteMilliseconds: max(baseline.durationMilliseconds, 1),
            tests: baseline.testsStarted,
            oneTestMilliseconds: cheapestTrial
        )
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
