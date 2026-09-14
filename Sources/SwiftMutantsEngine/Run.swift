// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsBuild
import SwiftMutantsDiscover
import SwiftMutantsSnapshot

public import Foundation
import SwiftMutantsValidate

public import SwiftMutantsConfig
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
        testArguments: [String] = []
    ) {
        self.root = root
        self.configuration = configuration
        self.runner = runner
        self.executable = executable
        self.workspace = workspace
        self.testArguments = testArguments
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
        let listing = try await list(environment: environment)
        guard !listing.catalog.mutants.isEmpty else {
            throw RunError(
                """
                nothing to mutate in \(root.path). `swift-mutants list --explain` says what \
                was passed over and why.
                """
            )
        }

        let subjects = try subjectsToValidate(listing, in: tree)
        progress(
            .instrumenting(
                files: subjects.count, mutants: listing.catalog.mutants.count))

        let validated = try await validate(
            subjects, in: tree, environment: environment, progress: progress)

        progress(.proving)
        try prove(validated.files.map(\.instrumented))

        progress(.building)
        let plan = try await buildTests(in: tree, environment: environment)

        let pipes = workspace.appending(path: "pipes")
        guard
            (try? FileManager.default.createDirectory(
                at: pipes, withIntermediateDirectories: true)) != nil
        else {
            throw RunError("\(pipes.path) could not be made, so the tests cannot be watched")
        }

        let calibration = try await calibrate(plan, in: pipes, progress: progress)
        let baseline = calibration.baseline
        let scheduler = calibration.scheduler

        let total = validated.files.reduce(0) { $0 + $1.instrumented.mutants.count }
        progress(.running(total: total))
        let results = await measure(validated, subjects, with: scheduler, progress: progress)

        guard let summary = RunSummary.of(results, rejected: validated.rejected.count) else {
            throw RunError("the counts did not add up, which is a defect in swift-mutants")
        }
        return RunOutcome(
            results: results,
            rejected: validated.rejected,
            summary: summary,
            baseline: baseline,
            filesInstrumented: validated.files.count
        )
    }

    /// Measures the suite with nothing awake, then works out what one mutant may cost.
    ///
    /// In that order, because the second comes from the first. The baseline gets a
    /// generous budget of its own: it is spent once, and the alternative is giving up on a
    /// package whose tests are simply long.
    private func calibrate(
        _ plan: TestPlan, in pipes: URL, progress: @Sendable (RunStage) -> Void
    ) async throws(RunError) -> (baseline: Verdict, scheduler: Scheduler) {
        let jobs = configuration.execution.jobs ?? 4
        let calibrating = Scheduler(
            plan: plan,
            runner: runner,
            scratch: pipes,
            timeout: configuration.test.timeout ?? Self.calibrationBudget,
            jobs: jobs
        )
        progress(.baseline)
        let baseline = try await provedBaseline(calibrating)

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
        return (
            baseline,
            Scheduler(plan: plan, runner: runner, scratch: pipes, timeout: budget, jobs: jobs)
        )
    }

    /// Runs the instrumented tree with nothing awake, and insists that it passes.
    ///
    /// This is what earns the right to report anything at all. If the tree with no mutant
    /// awake does not behave like the one the user wrote, every later answer is about a
    /// program nobody has - and would read as a score about theirs.
    private func provedBaseline(_ scheduler: Scheduler) async throws(RunError) -> Verdict {
        let baseline = await scheduler.baseline()
        guard baseline.outcome == .survived else {
            throw RunError(
                """
                the instrumented tree does not behave like the one you wrote: with no mutant \
                awake the tests came back \(baseline.outcome.rawValue). Every later answer \
                would be about a program nobody has, so the run stops here.
                \(Self.blame(baseline))
                """
            )
        }
        return baseline
    }

    /// Which tests said so, and what they said.
    ///
    /// Named, because "the baseline failed" is a sentence somebody can do nothing with.
    /// The usual cause is a test that asserts something about the source files rather than
    /// about the program - a lint gate, a golden file, a check on imports - and
    /// instrumentation changes those files by design. Knowing which test it was turns a
    /// dead end into a one-line exclusion.
    private static func blame(_ baseline: Verdict) -> String {
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
    private func measure(
        _ validated: Validation,
        _ subjects: [FileUnderValidation],
        with scheduler: Scheduler,
        progress: @Sendable (RunStage) -> Void
    ) async -> [MutantResult] {
        var results: [MutantResult] = []
        for (file, subject) in zip(validated.files, subjects) {
            guard let path = WorkspaceRelativePath(subject.name) else { continue }
            results += await scheduler.run(
                file.instrumented.mutants.sorted { $0.index < $1.index },
                in: path
            ) { progress(.finished($0)) }
        }
        return results
    }

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
