// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsCache
import SwiftMutantsReport

/// What the last run found, without running anything.
///
/// A mutation run takes long enough that nobody runs it again to look something up. The
/// report it left behind is the answer to every later question - what the score was, what
/// survived, what the compiler refused - and a report nothing can reach is a report nobody
/// has.
struct ReportCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Read what the last run found.",
        subcommands: [Latest.self, Merge.self, Clean.self],
        defaultSubcommand: Latest.self
    )

    /// Prints the last run's own account of itself.
    struct Latest: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "latest",
            abstract: "Print the last run's report.",
            discussion: """
                The whole account of the run, as JSON: every mutant by its full identity, \
                where it is, what became of it and what noticed it, beside the counts and \
                both scores.

                Reads what the last run left behind; it runs nothing.
                """
        )

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
            print(String(decoding: try RunReport.encoded(report), as: UTF8.self))
        }
    }

    /// Puts the shares of one run back together.
    struct Merge: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "merge",
            abstract: "Put the shares of a sharded run back together.",
            discussion: """
                Takes the reports several machines wrote - `swift-mutants run --shard 2/5 \
                --json > shard-2.json` - and writes one about the whole package to standard \
                output.

                Every mutant appears once, with the answer from whichever share measured \
                it, and the counts are worked out again from those answers rather than \
                added up from summaries that each counted the others as not run.
                """
        )

        @Argument(help: "The reports to merge, one per share.")
        var shares: [String] = []

        func run() async throws {
            guard shares.count > 1 else {
                throw ValidationError(
                    "give this the reports of two or more shares; one share is not a run.")
            }
            var read: [RunReport] = []
            for path in shares {
                guard let report = ReportStore.read(from: URL(filePath: path)) else {
                    throw ValidationError("\(path) is not a report this build can read.")
                }
                read.append(report)
            }
            guard let merged = SwiftMutantsReport.Merge.of(read) else {
                throw ValidationError(
                    """
                    those are not shares of one run: they describe different files. Merging \
                    them would give a score about a program nobody has.
                    """
                )
            }
            print(String(decoding: try RunReport.encoded(merged), as: UTF8.self))
        }
    }

    /// Forgets what this package's runs found.
    struct Clean: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "clean",
            abstract: "Forget what this package's runs found.",
            discussion: """
                Removes the stored report and every answer remembered from earlier runs, so \
                the next one measures everything again. Nothing in your repository is \
                touched, because nothing of this was ever kept there.
                """
        )

        @Option(name: .long, help: "The package to forget. Defaults to the current one.")
        var packagePath: String?

        func run() async throws {
            let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
            let forgotten = Self.forget(for: root)
            print(Narration.forgotten(forgotten))
        }

        /// Removes everything kept about a package, and says how much there was.
        static func forget(for root: URL) -> Int {
            let kept = [
                ReportStore.location(for: root),
                OutcomeCache.location(for: root),
                ProbeMemory.location(for: root),
                FailureReport.home(for: root),
            ]
            return kept.count { FileManager.default.fileExists(atPath: $0.path) }
                - kept.count {
                    FileManager.default.fileExists(atPath: $0.path)
                        && (try? FileManager.default.removeItem(at: $0)) == nil
                }
        }
    }
}
