// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsEngine

/// Asking git what somebody just wrote.
///
/// The honest answer to "fast enough to leave switched on". A whole-package run is
/// `Θ(mutants)` however clever the scheduling; a run scoped to the files somebody touched
/// is `Θ(mutants in those files)`, which is a handful - and unlike a cache of verdicts it
/// makes no claim about what it did not run.
@Suite("Changed files")
struct ChangedFilesTests {

    private struct GitFixtureSetupError: Error, CustomStringConvertible {
        let arguments: [String]
        let outcome: ProcessOutcome

        var description: String {
            "git \(arguments.joined(separator: " ")) (\(outcome.exitCode)): "
                + outcome.standardOutputText + outcome.standardErrorText
                + String((outcome.startFailure ?? "").prefix(2_048))
        }
    }

    private static let diagnosticLimit = 2_048

    /// A real repository, because what is being tested is an agreement with git.
    struct Repository {
        let root: URL
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static func repository(_ build: (URL) async throws -> Void) async throws -> Repository {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let hooks = root.appending(path: ".fixture-hooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            try await Self.git(["init", "-q", "-b", "main"], in: root)
            try await Self.git(["config", "core.hooksPath", hooks.path], in: root)
            try await Self.git(["config", "user.email", "t@example.com"], in: root)
            try await Self.git(["config", "user.name", "Test"], in: root)
            try await Self.git(["config", "commit.gpgsign", "false"], in: root)
            try await build(root)
            return Repository(root: root)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    static func git(_ arguments: [String], in root: URL) async throws {
        let outcome = await Runner(recorder: TraceRecorder(), outputLimit: diagnosticLimit).run(
            ProcessSpec(
                kind: .testFixture,
                executable: "/usr/bin/git",
                arguments: arguments,
                directory: root.path,
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                timeout: nil))
        guard outcome.exitCode == 0, outcome.startFailure == nil else {
            throw GitFixtureSetupError(arguments: arguments, outcome: outcome)
        }
    }

    @Test("reports a failed Git fixture command at its source")
    func failedFixtureCommand() async throws {
        let repository = try await Self.repository { _ in }
        defer { repository.cleanUp() }

        let failure = await #expect(throws: GitFixtureSetupError.self) {
            try await Self.git(["not-a-real-git-subcommand"], in: repository.root)
        }
        #expect(failure?.arguments == ["not-a-real-git-subcommand"])
        #expect(failure?.outcome.exitCode == 1)
        #expect(failure?.outcome.standardErrorText.contains("not-a-real-git-subcommand") == true)
    }

    @Test("removes a fixture after a failed seed commit and preserves the error")
    func failedSeedCommit() async throws {
        var failedRoot: URL?
        let failure = await #expect(throws: GitFixtureSetupError.self) {
            _ = try await Self.repository { root in
                failedRoot = root
                try await Self.git(
                    ["commit", "--allow-empty", "--author=invalid", "-m", "first"], in: root)
            }
        }
        #expect(failure?.arguments.first == "commit")
        #expect(failure?.outcome.exitCode != 0)
        let root = try #require(failedRoot)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("drains large Git output while retaining bounded failure diagnostics")
    func boundedFixtureDiagnostics() async throws {
        let repository = try await Self.repository { root in
            try Self.write(String(repeating: "old\n", count: 32_768), to: "before", in: root)
            try Self.write(String(repeating: "new\n", count: 32_768), to: "after", in: root)
        }
        defer { repository.cleanUp() }

        let difference = await #expect(throws: GitFixtureSetupError.self) {
            try await Self.git(
                ["diff", "--no-index", "--", "before", "after"], in: repository.root)
        }
        let output = try #require(difference?.outcome)
        #expect(output.exitCode == 1)
        #expect(output.standardOutput.count == Self.diagnosticLimit)
        #expect(output.standardOutputWasCut)

        let invalid = "invalid-" + String(repeating: "x", count: 16_384)
        let rejected = await #expect(throws: GitFixtureSetupError.self) {
            try await Self.git([invalid], in: repository.root)
        }
        let error = try #require(rejected?.outcome)
        #expect(error.exitCode == 1)
        #expect(error.standardError.count == Self.diagnosticLimit)
        #expect(error.standardErrorText.contains("invalid-"))
    }

    static func write(_ text: String, to path: String, in root: URL) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    static func changed(
        since reference: String, in root: URL
    ) async throws
        -> Set<WorkspaceRelativePath>
    {
        try await ChangedFiles(root: root, runner: Runner(recorder: TraceRecorder()))
            .since(reference)
    }

    @Test("finds a file edited since the reference")
    func edited() async throws {
        let repository = try await Self.repository { root in
            try Self.write("let a = 1", to: "Sources/A.swift", in: root)
            try Self.write("let b = 2", to: "Sources/B.swift", in: root)
            try await Self.git(["add", "."], in: root)
            try await Self.git(["commit", "-q", "-m", "first"], in: root)
            try Self.write("let a = 2", to: "Sources/A.swift", in: root)
        }
        defer { repository.cleanUp() }

        let changed = try await Self.changed(since: "HEAD", in: repository.root)
        #expect(changed.map(\.rendered).sorted() == ["Sources/A.swift"])
    }

    /// The change somebody most wants measured is the one they have not committed yet, and
    /// a new file is both the likeliest thing to want measured and the likeliest to be
    /// missed - git does not mention it unless asked separately.
    @Test("finds a file that is not tracked at all")
    func untracked() async throws {
        let repository = try await Self.repository { root in
            try Self.write("let a = 1", to: "Sources/A.swift", in: root)
            try await Self.git(["add", "."], in: root)
            try await Self.git(["commit", "-q", "-m", "first"], in: root)
            try Self.write("let c = 3", to: "Sources/C.swift", in: root)
        }
        defer { repository.cleanUp() }

        let changed = try await Self.changed(since: "HEAD", in: repository.root)
        #expect(changed.map(\.rendered).sorted() == ["Sources/C.swift"])
    }

    @Test("finds staged work as well as unstaged")
    func staged() async throws {
        let repository = try await Self.repository { root in
            try Self.write("let a = 1", to: "Sources/A.swift", in: root)
            try Self.write("let b = 2", to: "Sources/B.swift", in: root)
            try await Self.git(["add", "."], in: root)
            try await Self.git(["commit", "-q", "-m", "first"], in: root)
            try Self.write("let a = 9", to: "Sources/A.swift", in: root)
            try await Self.git(["add", "Sources/A.swift"], in: root)
            try Self.write("let b = 9", to: "Sources/B.swift", in: root)
        }
        defer { repository.cleanUp() }

        let changed = try await Self.changed(since: "HEAD", in: repository.root)
        #expect(changed.map(\.rendered).sorted() == ["Sources/A.swift", "Sources/B.swift"])
    }

    @Test("finds nothing when nothing changed")
    func unchanged() async throws {
        let repository = try await Self.repository { root in
            try Self.write("let a = 1", to: "Sources/A.swift", in: root)
            try await Self.git(["add", "."], in: root)
            try await Self.git(["commit", "-q", "-m", "first"], in: root)
        }
        defer { repository.cleanUp() }

        #expect(try await Self.changed(since: "HEAD", in: repository.root).isEmpty)
    }

    /// A reference nobody has is a mistake worth a sentence, not a run that quietly
    /// measures nothing and reports full marks.
    @Test("says so when the reference does not exist")
    func unknownReference() async throws {
        let repository = try await Self.repository { root in
            try Self.write("let a = 1", to: "Sources/A.swift", in: root)
            try await Self.git(["add", "."], in: root)
            try await Self.git(["commit", "-q", "-m", "first"], in: root)
        }
        defer { repository.cleanUp() }

        let failure = await #expect(throws: RunError.self) {
            try await Self.changed(since: "no-such-branch", in: repository.root)
        }
        #expect(failure?.description.contains("git diff") == true, "\(failure as Any)")
    }

    /// Somewhere that is not a repository at all.
    @Test("says so when there is no repository")
    func notARepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: RunError.self) {
            try await Self.changed(since: "HEAD", in: root)
        }
    }
}
