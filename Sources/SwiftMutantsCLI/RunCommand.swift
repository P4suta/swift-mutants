// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsValidate
import SwiftMutantsReport
import SwiftMutantsTempOwner
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

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Leave the copy behind, and say where it is.",
            discussion: """
                A run happens inside a copy that is deleted when it ends. When something \
                goes wrong, that copy is the only place it exists: the instrumented \
                sources, the tree the compiler was looking at, the build it did there. \
                Keeping it is how a failure becomes something you can reproduce by hand.
                """
        ))
    var keepTemp = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Whether to reuse answers an earlier run established: auto, on, or off.",
            discussion: """
                A mutant is answered from an earlier run only while everything that answer \
                rests on is unchanged: the mutant itself, this build of swift-mutants, and \
                every file the tests that reach it were seen to execute - including the \
                tests themselves.

                That assumes a test which runs a file evaluates a mutant's guard in it, \
                which holds everywhere except a region where every statement was suppressed \
                as arid. `off` is the answer if you need the guarantee rather than the \
                speed; it reads nothing and writes nothing.
                """
        ))
    var cache: CacheMode = .auto

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Ask the compiler which survivors could never have been caught.",
            discussion: """
                A survivor is either a hole in your tests or a mutant that should never \
                have been made. `x * 1` and `x` compile to the same instructions, so no \
                test can tell them apart - and reporting one tells you to go and look for a \
                hole that is not there, which costs your afternoon rather than a machine's.

                Off by default because it costs one compile of one module per survivor. \
                What it buys is an answer no amount of test-writing would ever change.
                """
        ))
    var tce = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "This machine's share of the catalogue, as 2/5.",
            discussion: """
                Every machine works out the same split without any of them talking to the \
                others, because a mutant's share is decided from its own identity - so \
                adding one mutant to one file does not move every mutant after it to a \
                different machine, nor throw away what those machines already knew.

                A score from one share is a score about that share, and the run says so. \
                `report merge` puts the pieces back together into one answer about the \
                package.
                """
        ))
    var shard: Shard?

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: ArgumentHelp(
            "Documents to write into the package: json, html, sarif.",
            discussion: """
                Written to `reports/mutation/`, which is the one place this tool writes \
                into your repository - and only when you ask. `json` is the projection the \
                Stryker ecosystem reads; `html` is one self-contained page that asks the \
                network for nothing; `sarif` is what a code host takes to annotate a pull \
                request and to remember which survivors you have already dismissed.

                The canonical account of a run is `--json`, which prints it, and `report \
                latest`, which reads the one the last run left behind.
                """
        ))
    var report: [ReportFormat] = []

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Write the run's own report to standard output instead of a summary.",
            discussion: """
                The whole account of the run: every mutant by its full identity, where it \
                is, what became of it and what noticed it, beside the counts and both \
                scores. Every key is present every time, and a number nobody measured is \
                null rather than zero.
                """
        ))
    var json = false

    func run() async throws {
        // A line at a time, even when nobody is watching a terminal. Output to a file or a
        // pipe is buffered in blocks by default, so a run that takes an hour writes a CI
        // log that is empty for an hour and then complete - which is the same as no
        // progress at all for the person reading it, and worse if the run is killed before
        // it flushes.
        _ = unsafe setvbuf(stdout, nil, _IOLBF, 0)

        let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
        let temporary = FileManager.default.temporaryDirectory
        let workspace = temporary.appending(path: "swift-mutants-\(UUID().uuidString)")
        defer {
            if keepTemp {
                print(Narration.kept(workspace))
            } else {
                try? FileManager.default.removeItem(at: workspace)
            }
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // This one is ours, and the ones nobody is running in any more are nobody's. A run
        // works inside a copy of the whole package, build directory included, so an
        // interrupted run leaves hundreds of megabytes behind - and interrupting a
        // mutation run is an ordinary thing to do.
        try? TempOwner.claim(workspace)
        let swept = TempOwner.sweep(in: temporary, besides: workspace)
        if swept > 0 { print(Narration.swept(swept)) }

        let progress = RunProgress()
        // One recorder for the whole run. Every subprocess passes through it, so when a run
        // fails an hour in, what it did is already written down - and this is what reads it
        // back out, because the moment somebody needs it is the moment the run is over.
        let recorder = TraceRecorder()
        let outcome: RunOutcome
        do {
            outcome = try await Run(
                root: root,
                configuration: asked,
                runner: Runner(recorder: recorder),
                workspace: workspace,
                testArguments: testArguments,
                changedSince: changed
            ).run(environment: Ambient.environment) { progress.report($0) }
        } catch {
            let written = FailureReport.write(
                "\(error)",
                recorder: recorder,
                environment: Ambient.environment,
                keptAt: keepTemp ? workspace : nil,
                into: FailureReport.home(for: root)
            )
            if let written { print(Narration.diagnosed(written)) }
            throw error
        }

        let account = RunReport(of: outcome)
        // Kept before it is printed, so that a run whose output somebody scrolled past is
        // still a run `explain` can answer about. Failing to keep it is a warning rather
        // than a failure: the run answered the question it was asked.
        try? ReportStore.write(account, to: ReportStore.location(for: root))
        let published = (try? Publishing.write(account, formats: Set(report), into: root)) ?? []

        if json {
            print(String(decoding: try RunReport.encoded(account), as: UTF8.self))
        } else {
            Self.summarise(outcome)
            for file in published { print(Narration.published(file, relativeTo: root)) }
            print(Narration.explainable(outcome.summary.survived))
            Self.annotate(account, in: Ambient.environment)
        }
        // Exit 1 is reserved for a policy somebody asked for. A run that completed and
        // found survivors has not failed - it has answered - and a tool that exited
        // non-zero for answering would be a tool people stop running.
        if strict, outcome.summary.survived > 0 { throw ExitCode(1) }
    }

    /// What the flags on this invocation amount to.
    private var asked: Configuration {
        var configuration = Configuration()
        configuration.execution.jobs = jobs
        configuration.execution.shard = shard
        configuration.execution.provesEquivalence = tce
        configuration.cache.mode = cache
        if let timeout { configuration.test.timeout = .seconds(timeout) }
        return configuration
    }

    /// Says it again where the person who caused it is looking, if anything is.
    ///
    /// Appended to the summary rather than written over it: a workflow has other steps and
    /// each of them owns part of that page.
    private static func annotate(_ report: RunReport, in environment: [String: String]) {
        guard Annotations.wanted(in: environment) else { return }
        for line in Annotations.workflowCommands(for: report) { print(line) }
        guard let file = Annotations.summaryFile(in: environment) else { return }
        let text = Annotations.stepSummary(for: report) + "\n"
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? Data(text.utf8).write(to: file)
            return
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
    }

    private static func summarise(_ outcome: RunOutcome) {
        for line in Narration.summary(of: outcome) { print(line) }
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
