// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiagnostics
import SwiftMutantsConsole
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

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp(
            "How many mutants to run at once. Defaults to this machine's cores.",
            discussion: """
                A mutant is one test process, and this tool turns your suite's own \
                in-process parallelism off so that which test caught a mutant is a fact \
                rather than a race. So a mutant is one busy thread, and the default is \
                however many places this machine has to put one.

                Turn it down if your suite cannot run beside itself - a shared port, a \
                fixture directory, a temporary file. A run checks for that before it \
                measures anything and says so rather than reporting the failures as kills.
                """
        ))
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

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Keep a recording of everything this run starts.",
            discussion: """
                Every subprocess a run starts passes through one recorder, so what it did \
                is written down whether or not anybody asked - this keeps it after the run \
                ends, when the terminal has scrolled and the copy is gone.

                `swift-mutants trace summary` then says where the time went. Off by \
                default because a recording is for the run you are about to have trouble \
                with rather than for every run.
                """
        ))
    var trace = false

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
    var cache: CacheMode?

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

    @Flag(
        name: [.customShort("v")],
        help: ArgumentHelp(
            "Say more. Twice says what the run started, as it happens.",
            discussion: """
                Once adds how long each phase took. Twice adds one line per recorded event, \
                indented two spaces so the account and the run can be told apart in one \
                scrollback: `grep '^  '` is what ran, `grep -v '^  '` is what was found.

                The recording happens either way. This only decides whether any of it is \
                said, which is why it is worth reaching for on the run that is going wrong \
                rather than the one after it.
                """
        ))
    var verbose: Int

    @Flag(
        name: .long,
        help: "Say nothing but errors. The exit code is the answer.")
    var quiet = false

    @Flag(
        name: .customLong("no-tui"),
        help: "Print lines rather than drawing, even on a terminal.")
    var noTui = false

    /// Whether to draw a screen that redraws, rather than printing lines.
    ///
    /// Drawing is for a person watching. A pipe gets lines, because a log full of cursor
    /// movement is a log nobody can read - so this is decided by asking where the output is
    /// going rather than by a preference, with a flag for somebody who knows better.
    ///
    /// Never alongside `-vv`: the account is a stream of lines and a screen moves the
    /// cursor over the last few, so one would scroll the other away. The account is the one
    /// somebody asked for by name.
    func draws(onATerminal terminal: Bool) -> Bool {
        terminal && !noTui && verbosity > .quiet && verbosity < .veryVerbose
    }

    /// How much this invocation says.
    ///
    /// `--quiet` wins over `-v`, because somebody who passed both wrote the second one for
    /// a reason and the quiet one is the safer of the two to honour: a script that is told
    /// too little still works.
    var verbosity: Verbosity {
        if quiet { return .quiet }
        return Verbosity(rawValue: min(Verbosity.veryVerbose.rawValue, 1 + verbose)) ?? .normal
    }

    func run() async throws {
        // A line at a time, even when nobody is watching a terminal. Output to a file or a
        // pipe is buffered in blocks by default, so a run that takes an hour writes a CI
        // log that is empty for an hour and then complete - which is the same as no
        // progress at all for the person reading it, and worse if the run is killed before
        // it flushes.
        _ = unsafe setvbuf(stdout, nil, _IOLBF, 0)

        let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
        let workspace = try claimWorkspace()
        defer {
            if keepTemp {
                print(Narration.kept(workspace))
            } else {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        // With `--json`, standard output carries the report and nothing else. Progress
        // went there too, so the report a script parsed began with eleven lines of
        // narration and was not JSON at all - `jq` on it fails at column 8 of line 1.
        //
        // Found by this repository's own release gate, which reads two numbers out of the
        // report with `jq` and could never have worked. A gate that had passed without
        // that being noticed would have been a gate asserting nothing.
        //
        // Stderr rather than silence, because somebody watching a forty-minute run still
        // wants to see it move, and a terminal shows both.
        let progress = Self.progress(
            verbosity: verbosity,
            drawing: draws(onATerminal: Ambient.isTerminal),
            reportOwnsStandardOutput: json
        )
        // One recorder for the whole run. Every subprocess passes through it, so when a run
        // fails an hour in, what it did is already written down - and this is what reads it
        // back out, because the moment somebody needs it is the moment the run is over.
        let settings = try ConfigurationFile.read(in: root)
        let ledger = Self.keepingAnswers(for: root)
        let kept = trace ? Self.keepingTrace(for: root) : nil
        if let kept { print(Narration.tracing(kept.path)) }
        let recorder = TraceRecorder(
            sinks: [LiveTrace(verbosity: verbosity)] + (kept.map { [$0] } ?? []))
        let outcome: RunOutcome
        do {
            outcome = try await Run(
                root: root,
                configuration: asked(startingFrom: settings),
                runner: Runner(recorder: recorder),
                workspace: workspace,
                testArguments: testArguments,
                changedSince: changed
            ).run(environment: Ambient.environment) {
                if case .finished(let result) = $0 { ledger?.record(Ledger.answer(for: result)) }
                progress.report($0)
            }
        } catch {
            progress.finish()
            diagnose(error, recorder: recorder, workspace: workspace, at: root)
            throw Self.leaving(error)
        }

        // Whatever was drawn stays on the screen, and the summary starts below it.
        progress.finish()
        try publish(outcome, at: root, settings: settings)
        // The report supersedes the running account, so it goes. What is left behind is a
        // ledger for a run that did not get here, which is the only kind worth keeping.
        try? FileManager.default.removeItem(at: Ledger.location(for: root))
        if let code = Gate.exitCode(
            survivors: Gate.survivors(of: outcome.summary),
            expectations: outcome.expectations,
            unanchored: outcome.unanchored,
            strict: strict,
            settings: settings.policy,
            scoring: outcome.summary.score.value
        ) {
            throw ExitCode(code)
        }
    }
}

extension RunCommand {

    /// Where a run's narration goes.
    ///
    /// With `--json`, standard output carries the report and nothing else: progress went
    /// there too, so a report piped into `jq` began with eleven lines of prose and was not
    /// JSON at all. Stderr rather than silence, because somebody watching a forty-minute
    /// run still wants to see it move and a terminal shows both.
    static func progress(
        verbosity: Verbosity,
        drawing: Bool,
        reportOwnsStandardOutput: Bool
    ) -> RunProgress {
        let elsewhere = reportOwnsStandardOutput
        let write: @Sendable (Data) -> Void = { text in
            if elsewhere {
                FileHandle.standardError.write(text)
            } else {
                FileHandle.standardOutput.write(text)
            }
        }
        return RunProgress(
            verbosity: verbosity,
            drawing: drawing,
            say: { write(Data(($0 + "\n").utf8)) },
            draw: { write(Data($0.utf8)) }
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
