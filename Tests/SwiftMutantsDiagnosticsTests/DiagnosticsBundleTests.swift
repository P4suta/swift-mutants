// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsDiagnostics

/// What a failed run leaves behind so that it can be diagnosed without being run again.
///
/// This is what makes a CI failure diagnosable from the artefacts instead of by asking
/// somebody to reproduce it, which on a mutation run is asking a great deal.
@Suite("Diagnostics bundle")
struct DiagnosticsBundleTests {

    static func scratch() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-bundle-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func contents(
        environmentNames: [String] = ["PATH", "A_SECRET"],
        preservedPaths: [String] = []
    ) -> DiagnosticsBundle.Contents {
        DiagnosticsBundle.Contents(
            error: "the baseline suite failed",
            errorChain: ["engine: baseline failed", "runner: exit 1"],
            environmentNames: environmentNames,
            doctor: #"{"swift":"6.3.3"}"#,
            trace: [TraceEvent(sequence: 1, kind: .phaseBegan(phase: "baseline"))],
            report: nil,
            preservedPaths: preservedPaths
        )
    }

    @Test("writes what a reader needs, and nothing a reader should not have")
    func writesTheAccount() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try DiagnosticsBundle.write(
            Self.contents(), to: root.appending(path: "run-1"))
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(
            written == [
                "doctor.json", "environment.txt", "error-chain.json", "error.txt",
                "preserved-paths.txt", "trace.jsonl",
            ]
        )
        #expect(
            try String(contentsOf: directory.appending(path: "error.txt"), encoding: .utf8)
                .contains("the baseline suite failed")
        )
    }

    /// A diagnostics bundle is something people attach to a bug report.
    @Test("records the names of the environment's variables and never their values")
    func environmentNamesOnly() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try DiagnosticsBundle.write(
            Self.contents(environmentNames: ["PATH", "AWS_SECRET_ACCESS_KEY"]),
            to: root.appending(path: "run-1")
        )
        let text = try String(
            contentsOf: directory.appending(path: "environment.txt"),
            encoding: .utf8
        )
        #expect(text.contains("AWS_SECRET_ACCESS_KEY"))
        #expect(!text.contains("="))
    }

    /// The order is the completeness marker. `error.txt` first is what makes the directory
    /// this tool's; `preserved-paths.txt` last is what says the directory is finished. A
    /// collector that could not tell a finished bundle from a half-written one would
    /// eventually take away the account of the crash it was collected for.
    @Test("is complete only once its last file is there")
    func completenessIsMarkedByTheLastFile() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try DiagnosticsBundle.write(
            Self.contents(), to: root.appending(path: "run-1"))
        #expect(DiagnosticsBundle.isComplete(directory))

        try FileManager.default.removeItem(at: directory.appending(path: "preserved-paths.txt"))
        #expect(!DiagnosticsBundle.isComplete(directory))
    }

    @Test("is not complete when it holds nothing at all")
    func anEmptyDirectoryIsNotABundle() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(!DiagnosticsBundle.isComplete(empty))
    }

    /// Keeping ten is a policy about disk; taking away a half-written one would be a policy
    /// about which crashes are worth explaining.
    @Test("collects finished bundles and leaves unfinished ones alone")
    func retentionSpareUnfinishedBundles() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 1...5 {
            _ = try DiagnosticsBundle.write(
                Self.contents(),
                to: root.appending(path: "run-\(index)")
            )
        }
        // One that died while being written.
        let unfinished = root.appending(path: "run-0-unfinished")
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: unfinished.appending(path: "error.txt"))

        try DiagnosticsBundle.retain(newest: 2, in: root)

        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left.contains("run-0-unfinished"), "an unfinished bundle was collected")
        #expect(left.contains("run-5"))
        #expect(left.contains("run-4"))
        #expect(!left.contains("run-1"))
    }

    /// An empty directory carries no marker, so neither the retention nor a manual clean
    /// could ever name it - and it would keep the root from being removed as well.
    @Test("discards a directory it created and could not put anything in")
    func discardsAnEmptyDirectoryItCreated() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appending(path: "run-1")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        DiagnosticsBundle.discardIfEmpty(empty)
        #expect(!FileManager.default.fileExists(atPath: empty.path))
    }

    /// The other half of the same rule. A directory that already held something is somebody
    /// else's, and taking it away because our write failed would be a diagnostic destroying
    /// evidence.
    @Test("leaves a directory that already held something")
    func leavesADirectoryThatHeldSomething() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = root.appending(path: "run-1")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("somebody else's".utf8).write(to: occupied.appending(path: "notes.txt"))

        DiagnosticsBundle.discardIfEmpty(occupied)
        #expect(FileManager.default.fileExists(atPath: occupied.appending(path: "notes.txt").path))
    }

    /// A write into a path that is already a file cannot start at all, and leaves the file
    /// alone.
    @Test("refuses a target that is not a directory, and disturbs nothing")
    func refusesANonDirectoryTarget() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "run-1")
        try Data("in the way".utf8).write(to: target)

        #expect(throws: (any Error).self) {
            try DiagnosticsBundle.write(Self.contents(), to: target)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "in the way")
    }
}
