// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsBuild
import SwiftMutantsRunner
import SwiftMutantsTrace

/// Answers one question: can this machine run swift-mutants here?
///
/// First in the help for a reason. This tool shells out to the `swift` on your `PATH`, and a
/// toolchain owned by a version manager is often not on it - a failure that otherwise
/// surfaces twenty minutes into a run as something that reads like a bug in the tool.
struct DoctorCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that this machine can run swift-mutants."
    )

    @Option(name: .long, help: "The package to check. Defaults to the current directory.")
    var packagePath: String?

    func run() async throws {
        let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
        var ready = true

        func report(_ passed: Bool, _ label: String, _ detail: String) {
            print(
                "  \(passed ? " ok " : "fail") \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(detail)"
            )
            if !passed { ready = false }
        }

        let runner = Runner(recorder: TraceRecorder())
        let version = await runner.run(
            ProcessSpec(
                kind: .versionProbe,
                executable: "/usr/bin/swift",
                arguments: ["--version"],
                directory: root.path,
                environment: Ambient.environment,
                timeout: .seconds(60)
            )
        )
        let versionText =
            String(decoding: version.standardOutput, as: UTF8.self)
            .split(separator: "\n").first.map(String.init) ?? ""
        report(version.exitCode == 0, "swift", versionText.isEmpty ? "not on PATH" : versionText)

        // The program that loads a test bundle on this platform. It lives in the
        // toolchain's `libexec` and carries no compatibility promise, so a machine without
        // it should be told now rather than after the first mutant fails to launch - which
        // is the failure that reads like a bug in this tool.
        do {
            let helper = try await SwiftPackageManager(
                root: root, runner: runner, executable: "/usr/bin/swift"
            ).testingHelper(environment: Ambient.environment)
            report(true, "test launcher", helper.path)
        } catch {
            report(false, "test launcher", error.description)
        }

        let manifest = root.appending(path: "Package.swift")
        report(
            FileManager.default.fileExists(atPath: manifest.path),
            "package",
            FileManager.default.fileExists(atPath: manifest.path)
                ? manifest.path : "no Package.swift in \(root.path)"
        )

        print("")
        print(
            ready
                ? "This machine can run swift-mutants."
                : "Fix the failures above, then run this again.")
        if !ready { throw ExitCode(2) }
    }
}
