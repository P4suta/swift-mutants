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

/// Says what a run would do, without doing any of it.
///
/// No snapshot, no build, no baseline, no test process. That makes it the command to reach
/// for before agreeing to let a run take an hour, and the one that still answers while the
/// package does not compile.
struct ListCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the mutants a run would measure, without measuring them."
    )

    @Option(name: .long, help: "The package to read. Defaults to the current directory.")
    var packagePath: String?

    @Flag(name: .long, help: "Also list what was passed over, and why.")
    var explain = false

    func run() async throws {
        let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
        let recorder = TraceRecorder()
        let listing = try await Lister(
            root: root,
            configuration: Configuration(),
            runner: Runner(recorder: recorder),
            executable: "/usr/bin/swift"
        ).list()

        for mutant in listing.catalog.mutants {
            let place = listing.positions[mutant.path]?.position(of: mutant.span.start)
            print(
                [
                    "\(mutant.path)\(place.map { ":\($0)" } ?? "")",
                    mutant.identity.shortForm,
                    mutant.rule.name,
                    "\(mutant.original) -> \(mutant.replacement)",
                ].joined(separator: "  ")
            )
        }

        if explain {
            for entry in listing.skips {
                let place = listing.positions[entry.path]?.position(of: entry.skip.span.start)
                print(
                    "  skipped \(entry.path)\(place.map { ":\($0)" } ?? "")  "
                        + "\(entry.skip.reason.rawValue)  hid \(entry.skip.candidatesHidden)"
                )
            }
        }

        // Always, never behind a flag. A comment that silences nothing is somebody
        // believing a mutant was dealt with when it was not, and the fix is one word.
        for entry in listing.unknownSuppressions {
            print(
                "  \(entry.path):\(entry.suppression.line): "
                    + "'\(entry.suppression.name)' is not an operator family, "
                    + "so this comment silences nothing"
            )
        }

        let hidden = listing.skips.reduce(0) { $0 + $1.skip.candidatesHidden }
        print(
            // "files read", not "files": the run afterwards counts the files it
            // *instruments*, which is smaller because a file with nothing to mutate is not
            // instrumented. Two bare counts of "files" in two phases read as the same
            // quantity disagreeing.
            "\(listing.catalog.mutants.count) mutants"
                + "  \(listing.skips.count) skips hiding \(hidden) more"
                + "  \(listing.filesRead) files read"
        )
        if !explain, !listing.skips.isEmpty {
            print("Run with --explain to see what was passed over and why.")
        }
    }
}
