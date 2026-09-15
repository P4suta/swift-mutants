// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsCore
import SwiftMutantsTrace

/// What a run did, read back after it is over.
///
/// Every subprocess a run starts passes through one recorder, so what it did is written down
/// whether or not anybody asked - and the moment somebody needs it is the moment the run is
/// over and the terminal has scrolled. The recording was being kept and nothing read it.
///
/// A recording is never evidence. It takes no part in a verdict, a mutant's identity or a
/// cache key, and a run whose recording could not be written says so and carries on.
struct TraceCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "trace",
        abstract: "Read what a run did, after it is over.",
        subcommands: [Summary.self, List.self]
    )

    /// Where a package's recordings are kept.
    static func home(for package: URL) -> URL {
        FailureReport.home(for: package).appending(path: "traces")
    }

    /// The recordings there, newest first.
    static func recordings(in home: URL) -> [URL] {
        let found =
            (try? FileManager.default.contentsOfDirectory(
                at: home,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
        return
            found
            .filter { $0.pathExtension == "jsonl" }
            .sorted { Self.written($0) > Self.written($1) }
    }

    /// When a recording was written, for putting the newest first.
    ///
    /// The distant past for one that cannot be read, so a file the filesystem will not
    /// answer about sorts last rather than first - the newest is what somebody asked for,
    /// and handing them an unreadable one instead would be answering the wrong question.
    private static func written(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// The events in one recording, skipping any line that is not one.
    ///
    /// A recording of a run that died ends mid-line, which is the case it exists for. The
    /// readable part of a cut-off line is a smaller event, and a smaller event is a wrong
    /// one - so it is left out rather than salvaged.
    static func events(in file: URL) -> [TraceEvent] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(TraceEvent.self, from: Data($0.utf8))
        }
    }

    /// Where a run's time went.
    struct Summary: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "summary",
            abstract: "Say where a run's time went.",
            discussion: """
                By what the commands were rather than by phase. The phases are printed as \
                they happen; what is left over is which kind of work the time went into, \
                and the two answers that matter want opposite responses. A run that is \
                mostly compiles wants fewer rounds. A run that is mostly trials wants \
                better coverage, or a wider machine.
                """
        )

        @Option(name: .long, help: "The package the run was about. Defaults to the current one.")
        var packagePath: String?

        @Option(name: .long, help: "A recording to read. Defaults to the most recent.")
        var file: String?

        func run() async throws {
            let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
            let recording =
                file.map { URL(filePath: $0) }
                ?? TraceCommand.recordings(in: TraceCommand.home(for: root)).first
            guard let recording else {
                throw ValidationError(
                    """
                    no recording here. Run with --trace to keep one; a run keeps none by \
                    default, because a recording is for the run you are about to have \
                    trouble with rather than for every run.
                    """
                )
            }
            print(recording.lastPathComponent)
            for line in TraceSummary.lines(of: TraceCommand.events(in: recording)) {
                print(line)
            }
        }
    }

    /// Which recordings are kept.
    struct List: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Say which recordings are kept, newest first."
        )

        @Option(name: .long, help: "The package to ask about. Defaults to the current one.")
        var packagePath: String?

        func run() async throws {
            let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
            let home = TraceCommand.home(for: root)
            let kept = TraceCommand.recordings(in: home)
            guard !kept.isEmpty else {
                print("no recordings here. Run with --trace to keep one.")
                return
            }
            print("kept in \(home.path)")
            for recording in kept {
                let events = TraceCommand.events(in: recording)
                print("  \(recording.lastPathComponent)  \(events.count) events")
            }
        }
    }
}
