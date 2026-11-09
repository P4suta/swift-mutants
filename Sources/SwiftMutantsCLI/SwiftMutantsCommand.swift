// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import ArgumentParser
import SwiftMutantsCore

/// The list and run command tree.
public struct SwiftMutantsCommand: AsyncParsableCommand {
    /// Command names, help, and version information.
    public static let configuration = CommandConfiguration(
        commandName: "swift-mutants",
        abstract: "Measure how existing Swift package tests detect source mutations.",
        version: Version.current,
        subcommands: [ListCommand.self, RunCommand.self]
    )

    /// Creates the command for ArgumentParser.
    public init() {}
}

struct PackageArguments: ParsableArguments {
    @Option(name: .customLong("package-path"), help: "Path to the SwiftPM package.")
    var packagePath = "."

    @Option(help: "Include a package-relative source glob; repeat to include more patterns.")
    var include: [String] = []

    @Option(help: "Exclude a package-relative source glob; repeat to exclude more patterns.")
    var exclude: [String] = []

    @Flag(help: "Write versioned JSON to stdout.")
    var json = false
}
