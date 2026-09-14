// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsValidate
import SwiftMutantsRunner
import SwiftMutantsTrace
import Synchronization

/// Measures what the tests catch.
///
/// The workspace is only ever read: the copy, the instrumentation, the build and every test
/// process happen somewhere else, so this is safe to point at a repository somebody is in
/// the middle of working in.
struct RunCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Measure what your tests catch.",
        discussion: """
            Builds a copy of your package once with every compilable mutant in it, then \
            wakes one per test process. Your working tree is never written to.

            A surviving mutant is a change to your code that every test still passed. \
            That is either a test worth writing or a line worth deleting.
            """
    )

    @Option(name: .long, help: "The package to measure. Defaults to the current directory.")
    var packagePath: String?

    @Option(name: .shortAndLong, help: "How many mutants to run at once.")
    var jobs: Int?

    @Option(name: .long, help: "How long one mutant may take, in seconds.")
    var timeout: Int?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Measure only what changed since this git reference.",
            discussion: """
                Work you have not committed counts, which is the point: the change most \
                worth measuring is the one you just made. The score is then about what \
                you changed, and the report says so.
                """
        ))
    var changed: String?

    @Flag(name: .long, help: "Exit non-zero if any mutant survived.")
    var strict = false

    @Argument(
        parsing: .postTerminator,
        help: ArgumentHelp(
            "Arguments for your tests, after `--`.",
            discussion: """
                Passed to the test bundle exactly as written and never interpreted. \
                They are a scope as well as a setting: narrowing the suite narrows what \
                the score is about.
                """
        ))
    var testArguments: [String] = []

    func run() async throws {
        // A line at a time, even when nobody is watching a terminal. Output to a file or a
        // pipe is buffered in blocks by default, so a run that takes an hour writes a CI
        // log that is empty for an hour and then complete - which is the same as no
        // progress at all for the person reading it, and worse if the run is killed before
        // it flushes.
        _ = unsafe setvbuf(stdout, nil, _IOLBF, 0)

        let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.execution.jobs = jobs
        if let timeout { configuration.test.timeout = .seconds(timeout) }

        let progress = RunProgress()
        let outcome = try await Run(
            root: root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            workspace: workspace,
            testArguments: testArguments,
            changedSince: changed
        ).run(environment: Ambient.environment) { progress.report($0) }

        Self.summarise(outcome)
        // Exit 1 is reserved for a policy somebody asked for. A run that completed and
        // found survivors has not failed - it has answered - and a tool that exited
        // non-zero for answering would be a tool people stop running.
        if strict, outcome.summary.survived > 0 { throw ExitCode(1) }
    }

    /// One survivor, in the words a fix needs: where it is, what it is called, what it did.
    private static func describe(_ result: MutantResult) -> String {
        [
            "\(result.path)",
            result.identity.shortForm,
            result.rule.name,
        ].joined(separator: "  ")
    }

    private static func summarise(_ outcome: RunOutcome) {
        let summary = outcome.summary
        let survivors = outcome.results.filter { $0.verdict.outcome == .survived }

        // Split, because they are different news and want different work. A mutant no test
        // reaches is usually the cheaper thing to deal with - often by deleting the code
        // rather than by writing an assertion - so it is listed first and separately.
        let unreached = survivors.filter { $0.verdict.startedTests.isEmpty }
        let unnoticed = survivors.filter { !$0.verdict.startedTests.isEmpty }

        if !unreached.isEmpty {
            print("")
            print("no test reaches these:")
            for result in unreached { print("  \(Self.describe(result))") }
        }
        if !unnoticed.isEmpty {
            print("")
            print("these ran and nothing noticed:")
            for result in unnoticed { print("  \(Self.describe(result))") }
        }

        print("")
        print(
            [
                "\(summary.killed) killed",
                "\(summary.survived) survived (\(summary.uncovered) of them unreached)",
                "\(summary.rejected) rejected",
                "\(summary.timedOut) timed out",
                "\(summary.errored) errored",
            ].joined(separator: "  ")
        )
        print(
            "score \(summary.score.rendered)  of covered code \(summary.score.renderedForCoveredCode)"
        )
    }
}

/// Says what a run is doing while it does it.
///
/// A line per mutant would bury the handful a person can act on, and no line at all leaves
/// somebody watching a silent terminal for half an hour wondering whether it has hung -
/// which is what the first run of this tool against this repository felt like. So: counts,
/// periodically, and the survivors at the end where they are sorted.
///
/// Counts rather than names, because results arrive from whichever worker finished first.
/// A line naming mutants in that order would differ between two runs of the same package,
/// and the one thing a report must not do is change shape because a machine was busy.
private final class RunProgress: @unchecked Sendable {
    /// One line per phase, and a counter while the mutants run.
    ///
    /// A line per mutant would bury the handful a person can act on, and no line at all
    /// leaves somebody watching a silent terminal for half an hour wondering whether it
    /// has hung - which is what the first run of this tool against this repository felt
    /// like. So: counts, periodically, and the survivors at the end where they are sorted.
    ///
    /// Counts rather than names, because results arrive from whichever worker finished
    /// first. A line naming mutants in that order would differ between two runs of the
    /// same package, and the one thing a report must not do is change shape because a
    /// machine was busy.

    /// How often to say something, in mutants.
    ///
    /// Often enough to show movement on a small package, rare enough not to scroll a
    /// large one away.
    static let every = 25

    private let lock = Mutex(RunCounts())

    /// What has come back so far.
    private struct RunCounts {
        var done = 0
        var killed = 0
        var survived = 0
        var total = 0
    }

    /// Says what phase a run has reached, and how far through the mutants it is.
    func report(_ stage: RunStage) {
        switch stage {
        case .finished(let result): finished(result)
        default: announce(stage)
        }
    }

    /// One line for each step of validation.
    ///
    /// Each round is a build of somebody's package, which is the slowest thing this tool
    /// does. A person watching twenty silent minutes cannot tell a second round from a
    /// hang, and the difference matters: one is progress and the other is a bug.
    private static func validating(_ step: Validator.Progress) -> String {
        switch step {
        case .compiling(let round, let mutants):
            round == 1
                ? "building with all \(mutants) mutants in, to see which compile"
                : "  building again, \(mutants) left"
        case .refused(_, let count):
            "  the compiler refused \(count)"
        case .halving(let mutants, let unplaceable):
            "  the compiler would not say which, so halving \(mutants) mutants"
                + (unplaceable.map {
                    "\n  it said: \($0.file):\($0.position): \($0.message)"
                } ?? "")
        }
    }

    /// One line for each phase a run passes through.
    private func announce(_ stage: RunStage) {
        if case .running(let total) = stage { lock.withLock { $0.total = total } }
        if let line = Self.line(for: stage) { print(line) }
    }

    /// What each phase says, or nothing for the ones that say it themselves.
    private static func line(for stage: RunStage) -> String? {
        switch stage {
        case .snapshotting: "copying the package"
        case .discovering: "reading the sources"
        case .instrumenting(let files, let mutants):
            "instrumenting \(mutants) mutants across \(files) files"
        case .proving: "proving every mutant is in the tree"
        case .building: "building the tests, once"
        case .baseline: "running the tests with nothing awake"
        case .validating(let step): Self.validating(step)
        default: Self.measurement(for: stage)
        }
    }

    /// The lines that carry a number somebody will want to reason about.
    private static func measurement(for stage: RunStage) -> String? {
        switch stage {
        case .calibrated(let budget):
            "  giving each mutant \(budget.seconds) seconds, from how long that took"
        case .probing(let tests): "asking each of \(tests) tests what it reaches"
        case .covered(let uncovered, let average):
            "  nothing reaches \(uncovered) of them; the rest face \(oneDecimal(average)) "
                + "tests each, not the whole suite"
        case .scoped(let reference, let files):
            files == 0
                ? "nothing has changed since \(reference)"
                : "measuring only what changed since \(reference): \(files) files"
        case .running(let total): "running \(total) mutants"
        default: nil
        }
    }

    /// A number to one decimal place, without reaching for a variadic C function.
    ///
    /// `String(format:)` is `vsnprintf` underneath, which a package built with
    /// -strict-memory-safety will not let through unmarked - and marking it would be
    /// claiming a safety argument for printing a number.
    private static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(abs(tenths % 10))"
    }

    /// Counts one answer, and says how it is going every so often.
    private func finished(_ result: MutantResult) {
        let line = lock.withLock { counts -> String? in
            counts.done += 1
            if result.verdict.outcome == .killed { counts.killed += 1 }
            if result.verdict.outcome == .survived { counts.survived += 1 }
            guard counts.done.isMultiple(of: Self.every) || counts.done == counts.total else {
                return nil
            }
            return "  \(counts.done)/\(counts.total)  \(counts.killed) killed"
                + "  \(counts.survived) survived"
        }
        if let line { print(line) }
    }
}

extension Duration {
    /// Whole seconds, for a line somebody reads rather than a number anything computes.
    var seconds: Int { Int(components.seconds) }
}
