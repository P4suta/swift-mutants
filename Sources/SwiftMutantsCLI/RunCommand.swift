// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsTrace

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
        let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.execution.jobs = jobs
        if let timeout { configuration.test.timeout = .seconds(timeout) }

        let outcome = try await Run(
            root: root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            workspace: workspace,
            testArguments: testArguments
        ).run(environment: Ambient.environment) { Self.report($0) }

        Self.summarise(outcome)
        // Exit 1 is reserved for a policy somebody asked for. A run that completed and
        // found survivors has not failed - it has answered - and a tool that exited
        // non-zero for answering would be a tool people stop running.
        if strict, outcome.summary.survived > 0 { throw ExitCode(1) }
    }

    /// One line per phase, and nothing per mutant except when one is caught.
    ///
    /// A run of any size produces thousands of results, and a line each would bury the
    /// handful that a person can act on.
    private static func report(_ stage: RunStage) {
        switch stage {
        case .snapshotting: print("copying the package")
        case .discovering: print("reading the sources")
        case .instrumenting(let files, let mutants):
            print("instrumenting \(mutants) mutants across \(files) files")
        case .validating: print("asking the compiler which ones it will accept")
        case .proving: print("proving every mutant is in the tree")
        case .building: print("building the tests, once")
        case .baseline: print("running the tests with nothing awake")
        case .running(let total): print("running \(total) mutants")
        case .finished: break
        }
    }

    private static func summarise(_ outcome: RunOutcome) {
        let summary = outcome.summary
        let survivors = outcome.results.filter { $0.verdict.outcome == .survived }
        if !survivors.isEmpty {
            print("")
            print("survived:")
            for result in survivors {
                print("  \(result.path)  \(result.identity.shortForm)  \(result.rule.name)")
            }
        }

        print("")
        print(
            [
                "\(summary.killed) killed",
                "\(summary.survived) survived",
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
