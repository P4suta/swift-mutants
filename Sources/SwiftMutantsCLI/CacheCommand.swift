// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsCache
import SwiftMutantsReport

/// What this tool has kept, and how to stop it keeping something.
///
/// A cache exists to be trusted, and the moment somebody stops trusting one is the moment
/// they need to see inside it. There was no way to: the answers live outside the repository
/// under a name that is a digest, which is right - a run must not write into somebody's tree
/// and two packages must not share answers - and it leaves a person who suspects a stale
/// answer with nothing to do but find and delete a directory nobody told them about.
///
/// `--cache off` is not that. It says "do not use one this time", which is a different
/// sentence from "show me what is in there" and from "be rid of it".
struct CacheCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "See what answers are kept, and clear them.",
        subcommands: [Status.self, Clean.self, Sweep.self]
    )

    /// Everything this tool keeps about one package.
    ///
    /// One list, used by both `status` and `clean`, because the failure otherwise is silent
    /// and certain: somebody adds a fourth thing the tool keeps - a ledger of answers, say -
    /// wires it into a run, and `clean` goes on forgetting three of them. What is left is a
    /// file nobody asked for, outliving the command that exists to remove it.
    ///
    /// The report is in the list. It is not a cache, but somebody clearing what this tool
    /// remembers about their package means all of it, and a report left behind would have
    /// `explain` answering about a run whose answers are gone.
    static func kept(for package: URL) -> [URL] {
        [
            OutcomeCache.location(for: package),
            ProbeMemory.location(for: package),
            ReportStore.location(for: package),
            Ledger.location(for: package),
        ]
    }

    /// What is kept for this package, and for every other.
    struct Status: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Say what is kept, for this package and in total."
        )

        @Option(name: .long, help: "The package to ask about. Defaults to the current one.")
        var packagePath: String?

        func run() async throws {
            let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
            let home = CacheInventory.home()
            let all = CacheInventory.entries(in: home)
            let mine = Set(CacheCommand.kept(for: root).map(\.standardizedFileURL))

            print("kept in \(home.path)")
            print("  all packages   \(CacheInventory.summary(of: all, now: Date()))")
            print(
                "  this package   "
                    + CacheInventory.summary(
                        of: all.filter { mine.contains($0.file.standardizedFileURL) },
                        now: Date()))
            print("")
            print(
                "`swift-mutants cache clean` forgets this package's answers; "
                    + "`cache sweep --days 30` forgets whatever nothing has written to lately.")
        }
    }

    /// Forgets what is kept for one package.
    struct Clean: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "clean",
            abstract: "Forget everything kept for this package."
        )

        @Option(name: .long, help: "The package to forget. Defaults to the current one.")
        var packagePath: String?

        func run() async throws {
            let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
            let forgotten = CacheCommand.kept(for: root)
                .filter { FileManager.default.fileExists(atPath: $0.path) }

            for file in forgotten { try? FileManager.default.removeItem(at: file) }
            print(
                forgotten.isEmpty
                    ? "nothing was kept for this package."
                    : "forgot \(forgotten.count) file\(forgotten.count == 1 ? "" : "s").")
        }
    }

    /// Forgets what nothing has written to lately, across every package.
    struct Sweep: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "sweep",
            abstract: "Forget what nothing has written to in a while, for every package.",
            discussion: """
                One file per package, so what accumulates is packages: a machine that \
                measured forty repositories last year keeps forty of them, for \
                repositories that may no longer exist.

                Counted by the file's own age rather than by anything inside it - an answer \
                carries no date, and giving it one would be a schema change to answer a \
                question the timestamp already answers.
                """
        )

        @Option(name: .long, help: "Forget what nothing has written to in this many days.")
        var days: Int = 30

        @Flag(name: .long, help: "Say what would go, and take nothing.")
        var dryRun = false

        func run() async throws {
            let home = CacheInventory.home()
            let stale = CacheInventory.stale(
                CacheInventory.entries(in: home), olderThan: days, now: Date())
            guard !stale.isEmpty else {
                print("nothing has been untouched for \(days) days.")
                return
            }
            for entry in stale {
                print("  \(dryRun ? "would forget" : "forgot") \(entry.file.lastPathComponent)")
            }
            guard !dryRun else { return }
            for entry in stale { try? FileManager.default.removeItem(at: entry.file) }
        }
    }
}
