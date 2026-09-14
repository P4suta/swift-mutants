// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import ArgumentParser
import SwiftMutantsCore

/// The command tree.
///
/// With no arguments, help is printed. Mutation starts only with `run`, because a tool that
/// began an hour of work because somebody typed its name would be a tool people type
/// carefully.
public struct SwiftMutantsCommand: AsyncParsableCommand {

    /// The command tree, and the words that introduce it.
    public static let configuration = CommandConfiguration(
        commandName: "swift-mutants",
        abstract: "Mutation testing for Swift that is fast enough to leave switched on.",
        discussion: """
            swift-mutants instruments every compilable mutant once into a disposable copy of \
            your package, then wakes one per test process through an environment variable. \
            Your working tree is never written to.

            `list` is the fast path: it reads your sources and says what it would do, \
            without building anything. `explain` says everything known about one mutant \
            from the last run, without running anything.
            """,
        version: Version.current,
        subcommands: [
            RunCommand.self, ListCommand.self, ExplainCommand.self, BrowseCommand.self,
            ApplyCommand.self, WhySkippedCommand.self, ReportCommand.self, DoctorCommand.self,
        ],
        defaultSubcommand: nil
    )

    /// Creates the top-level command. `ArgumentParser` calls this.
    public init() {}
}
