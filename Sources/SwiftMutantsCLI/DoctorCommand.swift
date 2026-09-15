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

        await Self.sayAboutStrays(runner: runner, in: root)

        print("")
        print(
            ready
                ? "This machine can run swift-mutants."
                : "Fix the failures above, then run this again.")
        if !ready { throw ExitCode(2) }
    }

    /// Says what this tool has left running on this machine, and nothing else.
    ///
    /// Not a failure. A compile in one of this tool's trees might be a run somebody started
    /// a moment ago, and what to do about a process is theirs to decide - a tool that
    /// reached for one it did not start would be a worse thing than the leak.
    ///
    /// It exists because the leak is real and was invisible. A killed `swift-mutants`
    /// leaves its compiles running, because its children are in a process group of their
    /// own so that a Ctrl-C does not take a compiler down mid-write; the deadline that
    /// would have stopped them dies with the parent. Reaping on a signal is deliberately
    /// not built - it needs a preallocated lock-free registry and a careless version is
    /// worse than the leak, because a process id is reused - and the trouble with a
    /// deliberate decision in a commit message is that the person who meets a compiler
    /// which has been running for five hours is not reading commit messages.
    ///
    /// Measured: five hours and seventeen minutes on one file, on a machine whose owner
    /// could not see why it was busy.
    static func sayAboutStrays(runner: Runner, in root: URL) async {
        let listing = await runner.run(
            ProcessSpec(
                kind: .versionProbe,
                executable: "/bin/ps",
                arguments: ["-axo", "pid,etime,command"],
                directory: root.path,
                environment: Ambient.environment,
                timeout: .seconds(30)
            )
        )
        guard listing.exitCode == 0 else { return }
        let found = StrayCompiles.reading(String(decoding: listing.standardOutput, as: UTF8.self))
        guard let oldest = found.first else { return }

        print("")
        print(
            "  note  \(found.count) compile\(found.count == 1 ? " is" : "s are") running in a "
                + "swift-mutants copy, the oldest for \(oldest.elapsed) (pid \(oldest.pid))."
        )
        print(
            """
              A run in progress has these. A run that was interrupted leaves them: its \
            children are in a process group of their own so a Ctrl-C does not stop a \
            compiler mid-write, and the deadline goes with the parent. Nothing here will \
            stop one for you.
            """
        )
        for stray in found.prefix(3) {
            print("    pid \(stray.pid)  \(stray.elapsed)  \(stray.tree)")
        }
    }
}
