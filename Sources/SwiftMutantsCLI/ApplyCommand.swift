// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsReport

/// Prints one mutant as a change somebody can apply.
///
/// `explain` says what a survivor is. The next question is always the same - "would a test
/// actually catch this if I wrote one?" - and the only way to answer it is to make the
/// change and run under a debugger.
///
/// It prints rather than writes. A tool that edited somebody's working tree because they
/// typed a subcommand would be a tool they use once; `git apply` is theirs to run, and
/// `git apply -R` puts it back.
struct ApplyCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Print one mutant as a patch.",
        discussion: """
            Takes the identity a report prints, or enough of the front of it to be \
            unambiguous, and writes a unified diff to standard output.

            Nothing in your working tree is touched. Pipe it to `git apply` to make the \
            change and `git apply -R` to put it back:

                swift-mutants apply 4fcc205c | git apply
                swift-mutants apply 4fcc205c | git apply -R

            The patch carries the lines around the change, so `git apply` refuses it if the \
            file has moved on since the run - which is the answer you want, rather than an \
            edit somewhere it does not belong.
            """
    )

    @Argument(help: "The mutant's identity, or enough of the front of it.")
    var mutant: String

    @Option(name: .long, help: "The package the run was about. Defaults to the current one.")
    var packagePath: String?

    func run() async throws {
        let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
        guard let report = ReportStore.read(from: ReportStore.location(for: root)) else {
            throw ValidationError(
                """
                nothing has been measured here yet. Run `swift-mutants run` first; this \
                reads what that leaves behind.
                """
            )
        }
        guard let found = Explanation.find(mutant, among: report.mutants) else {
            throw ValidationError(ExplainCommand.nothingFound(mutant, in: report))
        }
        guard
            let source = try? String(
                contentsOf: root.appending(path: found.path), encoding: .utf8)
        else {
            throw ValidationError(
                "\(found.path) could not be read, so there is nothing to make a patch against.")
        }
        guard let patch = Patch.of(found, in: source) else {
            throw ValidationError(
                """
                \(found.path) is not what it was when this mutant was measured, so a patch \
                for it would apply somewhere it does not belong. Run `swift-mutants run` \
                again first.
                """
            )
        }
        print(patch, terminator: "")
    }
}
