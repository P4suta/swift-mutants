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

    /// A real repository, because what is being tested is an agreement with git.
    struct Repository {
        let root: URL
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static func repository(_ build: (URL) throws -> Void) throws -> Repository {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.git(["init", "-q", "-b", "main"], in: root)
        try Self.git(["config", "user.email", "t@example.com"], in: root)
        try Self.git(["config", "user.name", "Test"], in: root)
        try Self.git(["config", "commit.gpgsign", "false"], in: root)
        try build(root)
        return Repository(root: root)
    }

    static func git(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
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
        let repository = try Self.repository { root in
            try Self.write("let a = 1", to: "Sources/A.swift", in: root)
            try Self.write("let b = 2", to: "Sources/B.swift", in: root)
            try Self.git(["add", "."], in: root)
            try Self.git(["commit", "-q", "-m", "first"], in: root)
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
        let repository = try Self.repository { root in
            try Self.write("let a = 1", to: "Sources/A.swift", in: root)
            try Self.git(["add", "."], in: root)
            try Self.git(["commit", "-q", "-m", "first"], in: root)
            try Self.write("let c = 3", to: "Sources/C.swift", in: root)
        }
        defer { repository.cleanUp() }

        let changed = try await Self.changed(since: "HEAD", in: repository.root)
        #expect(changed.map(\.rendered).sorted() == ["Sources/C.swift"])
    }

    @Test("finds staged work as well as unstaged")
    func staged() async throws {
        let repository = try Self.repository { root in
            try Self.write("let a = 1", to: "Sources/A.swift", in: root)
            try Self.write("let b = 2", to: "Sources/B.swift", in: root)
            try Self.git(["add", "."], in: root)
            try Self.git(["commit", "-q", "-m", "first"], in: root)
            try Self.write("let a = 9", to: "Sources/A.swift", in: root)
            try Self.git(["add", "Sources/A.swift"], in: root)
            try Self.write("let b = 9", to: "Sources/B.swift", in: root)
        }
        defer { repository.cleanUp() }

        let changed = try await Self.changed(since: "HEAD", in: repository.root)
        #expect(changed.map(\.rendered).sorted() == ["Sources/A.swift", "Sources/B.swift"])
    }

    @Test("finds nothing when nothing changed")
    func unchanged() async throws {
        let repository = try Self.repository { root in
            try Self.write("let a = 1", to: "Sources/A.swift", in: root)
            try Self.git(["add", "."], in: root)
            try Self.git(["commit", "-q", "-m", "first"], in: root)
        }
        defer { repository.cleanUp() }

        #expect(try await Self.changed(since: "HEAD", in: repository.root).isEmpty)
    }

    /// A reference nobody has is a mistake worth a sentence, not a run that quietly
    /// measures nothing and reports full marks.
    @Test("says so when the reference does not exist")
    func unknownReference() async throws {
        let repository = try Self.repository { root in
            try Self.write("let a = 1", to: "Sources/A.swift", in: root)
            try Self.git(["add", "."], in: root)
            try Self.git(["commit", "-q", "-m", "first"], in: root)
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
