// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation

/// Writes the file a project keeps its settings in, or says whether it is readable.
///
/// The configuration is read by every command, and nothing told anybody it existed. A
/// setting that works and cannot be discovered is a setting nobody uses - the same outcome
/// as one that does not work, and more to maintain.
struct InitCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Write a starter \(ConfigurationFile.name), with every setting explained.",
        discussion: """
            Every setting is commented out, so the file changes nothing until you uncomment \
            something. Commented rather than set, because a starter file that turned things \
            on would be this tool deciding about your package by being run once.

            With --check it writes nothing and says whether the file you have can be read, \
            which is the form for a gate.
            """
    )

    @Option(name: .long, help: "The package to write it in. Defaults to the current one.")
    var packagePath: String?

    @Flag(
        name: .long,
        help: "Write nothing; say whether the file that is there can be read.")
    var check = false

    func run() async throws {
        let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
        let file = root.appending(path: ConfigurationFile.name)
        let there = FileManager.default.fileExists(atPath: file.path)

        guard !check else {
            guard there else {
                print("no \(ConfigurationFile.name) here. Everything runs on the defaults.")
                return
            }
            // Read through the same path a run reads it, so that a gate passing here is a
            // gate saying a run will start. Anything else would be a second reader, and a
            // second reader is a second answer.
            _ = try ConfigurationFile.read(in: root)
            print("\(ConfigurationFile.name) reads.")
            return
        }

        // Never over what is already there. A configuration is something somebody wrote,
        // and a command that replaced it with a file of comments would be a command nobody
        // runs twice.
        guard !there else {
            throw ValidationError(
                """
                \(file.path) is already there, and this will not write over it. Delete it \
                first if you want to start again, or run with --check to see whether the \
                one you have reads.
                """
            )
        }

        try Data((StarterConfiguration.text + "\n").utf8).write(to: file)
        print("wrote \(file.path)")
        print("Every setting in it is commented out, so nothing has changed yet.")
    }
}
