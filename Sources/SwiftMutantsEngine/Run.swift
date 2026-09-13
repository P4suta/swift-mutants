// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsBuild
import SwiftMutantsDiscover
import SwiftMutantsSnapshot

public import Foundation
public import SwiftMutantsValidate

public import SwiftMutantsConfig
public import SwiftMutantsCore
public import SwiftMutantsExecute
import SwiftMutantsInstrument
public import SwiftMutantsRunner

/// Everything one mutation run established.
public struct RunOutcome: Sendable {

    /// What became of each mutant, file by file, in catalogue order.
    public let results: [MutantResult]

    /// What the compiler refused, in its own words.
    public let rejected: [Rejection]

    /// The counts, and the score derived from them.
    public let summary: RunSummary

    /// How the instrumented tree behaved with nothing awake.
    public let baseline: Verdict

    /// How many files were instrumented.
    public let filesInstrumented: Int
}

/// A run could not be carried out.
public struct RunError: Error, Hashable, CustomStringConvertible {

    /// What went wrong, in the words a fix needs.
    public let description: String

    init(_ description: String) { self.description = description }
}

/// What a run is doing, for somebody watching it.
public enum RunStage: Sendable, Hashable {
    case snapshotting
    case discovering
    case instrumenting(files: Int, mutants: Int)
    case validating
    case building
    case proving
    case baseline
    case running(total: Int)
    case finished(MutantResult)
}

/// The whole pipeline, from a package on disk to an answer about its tests.
///
/// Ordered the way it is because each step earns the right to the next. Nothing is built
/// until the compiler has said which mutants exist; nothing is run until the tree with
/// nothing awake behaves like the one the user wrote; and no score is reported about a tree
/// whose mutants could not be shown to be in it.
public struct Run: Sendable {

    private let root: URL
    private let configuration: Configuration
    private let runner: Runner
    private let executable: String
    private let workspace: URL
    private let testArguments: [String]

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

        progress(.validating)
        let validated = try await validate(subjects, in: tree, environment: environment)

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

        let scheduler = Scheduler(
            plan: plan,
            runner: runner,
            scratch: pipes,
            timeout: configuration.test.timeout ?? .seconds(120),
            jobs: configuration.execution.jobs ?? 4
        )
        progress(.baseline)
        let baseline = try await provedBaseline(scheduler)

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
                """
            )
        }
        return baseline
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

    // MARK: - Steps

    private func snapshot(_ progress: @Sendable (RunStage) -> Void) throws(RunError) -> URL {
        progress(.snapshotting)
        let tree = workspace.appending(path: "tree")
        do {
            _ = try Snapshot.create(of: root, at: tree)
        } catch {
            throw RunError("\(root.path) could not be copied: \(error)")
        }
        return tree
    }

    private func list(environment: [String: String]) async throws(RunError) -> Listing {
        do {
            return try await Lister(
                root: root, configuration: configuration, runner: runner, executable: executable
            ).list(environment: environment)
        } catch {
            throw RunError("\(root.path) could not be read: \(error)")
        }
    }

    /// The files to instrument, read from the copy rather than from the original.
    ///
    /// Read from the copy because that is what will be compiled, and a file that changed
    /// between the two would be a catalogue about one program and a build about another.
    private func subjectsToValidate(
        _ listing: Listing, in tree: URL
    ) throws(RunError) -> [FileUnderValidation] {
        var subjects: [FileUnderValidation] = []
        for path in listing.filesWithMutants {
            let file = tree.appending(path: path.rendered)
            guard let source = try? String(contentsOf: file, encoding: .utf8) else {
                throw RunError("\(file.path) could not be read out of the copy")
            }
            subjects.append(
                FileUnderValidation(
                    name: path.rendered,
                    source: source,
                    discovery: Discover.candidates(in: source, at: path)
                )
            )
        }
        return subjects
    }

    private func validate(
        _ subjects: [FileUnderValidation], in tree: URL, environment: [String: String]
    ) async throws(RunError) -> Validation {
        // SwiftPM rather than a bare `swiftc`, because a package is not a pile of files:
        // each target compiles on its own, against its own dependencies and search paths.
        // The same scratch directory the tests are built into, so the build that proves
        // the mutants compile *is* the build that produces them.
        let validator = Validator(
            compiler: SwiftBuildDriver(
                runner: runner,
                executable: executable,
                root: tree.path,
                scratch: workspace.appending(path: "build").path,
                environment: environment
            ),
            directory: tree
        )
        do {
            return try await validator.validate(subjects)
        } catch {
            throw RunError("the instrumented copy could not be validated: \(error)")
        }
    }

    /// Every mutant in the catalogue has to be in the file, before anything is run.
    ///
    /// Muter assumed insertion and reported four hundred mutants as newly surviving when in
    /// fact none had been inserted at all. Assuming is the mistake; this is the check that
    /// makes it impossible rather than unlikely.
    private func prove(_ files: [InstrumentedFile]) throws(RunError) {
        for file in files {
            let proof = ActivationProof.inSource(file)
            guard proof.isProved else {
                let missing = proof.absences.map(\.marker).prefix(3).joined(separator: ", ")
                throw RunError(
                    """
                    \(proof.expected - proof.found) of \(proof.expected) mutants are not in \
                    the instrumented file (\(missing)). Running would report them as \
                    surviving tests that never had a chance to catch them.
                    """
                )
            }
        }
    }

    private func buildTests(
        in tree: URL, environment: [String: String]
    ) async throws(RunError) -> TestPlan {
        do {
            let plan = try await SwiftPackageManager(
                root: tree, runner: runner, executable: executable
            ).buildForTesting(
                scratch: workspace.appending(path: "build").path,
                environment: environment,
                timeout: .seconds(1800)
            )
            guard !testArguments.isEmpty else { return plan }
            return TestPlan(
                executable: plan.executable,
                arguments: plan.arguments + testArguments,
                environment: plan.environment,
                directory: plan.directory,
                eventStreamVersion: plan.eventStreamVersion
            )
        } catch {
            throw RunError("the instrumented copy could not be built: \(error)")
        }
    }
}
