// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsEngine
import SwiftMutantsRunner
import SwiftMutantsTrace

/// Says what this tool passed over, and on what grounds.
///
/// A score is about the mutants that exist, and which ones exist is a decision this tool
/// made. A tool that suppressed a thousand of them and never said so would be reporting a
/// score about a program it chose rather than the one somebody wrote.
///
/// It builds nothing. Like `list`, it reads the package's description and its sources and
/// stops - so it answers while the package does not compile, which is exactly when somebody
/// is likely to be arguing with it.
struct WhySkippedCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "why-skipped",
        abstract: "Say what was passed over, and why.",
        discussion: """
            Every reason is listed, including the ones that hid nothing: a reason nobody has \
            met is a reason nobody can judge.

            `list --explain` says the same thing the other way round - every skip where it \
            is, rather than every reason and how much it took.
            """
    )

    @Option(name: .long, help: "The package to read. Defaults to the current directory.")
    var packagePath: String?

    @Option(name: .long, help: "Only this reason, by the name this prints.")
    var reason: String?

    func run() async throws {
        let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
        let listing = try await Lister(
            root: root,
            configuration: Configuration(),
            runner: Runner(recorder: TraceRecorder())
        ).list(environment: Ambient.environment)

        guard let reason else {
            for line in SkipSummary.lines(for: listing.skips) { print(line) }
            return
        }
        guard let wanted = SkipReason(rawValue: reason) else {
            throw ValidationError(
                """
                \(reason) is not a reason this tool has. It has: \
                \(SkipReason.allCases.map(\.rawValue).sorted().joined(separator: ", ")).
                """
            )
        }
        for entry in listing.skips where entry.skip.reason == wanted {
            let place = listing.positions[entry.path]?.position(of: entry.skip.span.start)
            print(
                "\(entry.path)\(place.map { ":\($0)" } ?? "")  "
                    + "hid \(entry.skip.candidatesHidden)"
            )
        }
    }
}
