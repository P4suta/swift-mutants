// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsEngine

/// Handing the copy the dependencies the original already fetched.
///
/// A snapshot leaves `.build` behind, which is right for build artefacts and wrong for the
/// dependency checkouts inside it: without them SwiftPM fetches every dependency again,
/// once per run. That is a network round trip and a set of credentials a mutation run has
/// no business needing - and on a machine whose git rewrites GitHub URLs to SSH, it is an
/// agent prompt in the middle of an hour-long job. Found exactly that way.
@Suite("Lent dependencies")
struct LentDependenciesTests {

    struct Pair {
        let root: URL
        let tree: URL
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: tree)
        }
    }

    static func pair(_ contents: [String: String]) throws -> Pair {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-lend-root-\(identifier)")
        let tree = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-lend-tree-\(identifier)")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        for (path, text) in contents {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        return Pair(root: root, tree: tree)
    }

    static func exists(_ path: String, in tree: URL) -> Bool {
        FileManager.default.fileExists(atPath: tree.appending(path: path).path)
    }

    @Test("lends the fetched sources")
    func lendsCheckouts() throws {
        let pair = try Self.pair([
            ".build/checkouts/swift-syntax/Package.swift": "// a dependency",
            ".build/repositories/swift-syntax-abc/HEAD": "ref",
        ])
        defer { pair.cleanUp() }

        Run.lendDependencies(from: pair.root, to: pair.tree)
        #expect(Self.exists(".build/checkouts/swift-syntax/Package.swift", in: pair.tree))
        #expect(Self.exists(".build/repositories/swift-syntax-abc/HEAD", in: pair.tree))
    }

    /// Never the built products. A run has to compile the instrumented tree itself, and
    /// inheriting object files from the original would be inheriting an answer about a
    /// different program.
    @Test("lends nothing that was built")
    func lendsNothingBuilt() throws {
        let pair = try Self.pair([
            ".build/checkouts/dep/Package.swift": "// a dependency",
            ".build/debug/Subject.o": "object code",
            ".build/arm64-apple-macosx/debug/Subject.swiftmodule": "a module",
            ".build/build.db": "a database",
        ])
        defer { pair.cleanUp() }

        Run.lendDependencies(from: pair.root, to: pair.tree)
        #expect(Self.exists(".build/checkouts/dep/Package.swift", in: pair.tree))
        #expect(!Self.exists(".build/debug/Subject.o", in: pair.tree))
        #expect(!Self.exists(".build/arm64-apple-macosx", in: pair.tree))
        #expect(!Self.exists(".build/build.db", in: pair.tree))
    }

    /// The pipeline has to actually do it. A helper that is right and unreachable is the
    /// shape the deadline derivation had until an integration test went looking.
    @Test("the snapshot step lends them")
    func theSnapshotStepLends() throws {
        let pair = try Self.pair([
            "Package.swift": "// a package",
            ".build/checkouts/dep/Package.swift": "// a dependency",
            ".build/debug/Subject.o": "object code",
        ])
        defer { pair.cleanUp() }

        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-lend-work-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tree = try Run(
            root: pair.root,
            configuration: Configuration(),
            runner: Runner(recorder: TraceRecorder()),
            workspace: workspace
        ).snapshot { _ in }

        #expect(Self.exists(".build/checkouts/dep/Package.swift", in: tree))
        #expect(!Self.exists(".build/debug/Subject.o", in: tree))
    }

    /// Best effort: a package that has never been built lends nothing and the run goes on
    /// to fetch as it would have anyway.
    @Test("says nothing when there is nothing to lend")
    func nothingToLend() throws {
        let pair = try Self.pair(["Package.swift": "// no build yet"])
        defer { pair.cleanUp() }

        Run.lendDependencies(from: pair.root, to: pair.tree)
        #expect(!Self.exists(".build", in: pair.tree))
    }

    /// And a copy that cannot be made is not a failure either.
    @Test("leaves a copy that cannot be made alone")
    func doesNotThrow() throws {
        let pair = try Self.pair([".build/checkouts/dep/Package.swift": "// a dependency"])
        defer { pair.cleanUp() }
        // Something already in the way, so the copy fails.
        try FileManager.default.createDirectory(
            at: pair.tree.appending(path: ".build/checkouts"), withIntermediateDirectories: true)

        Run.lendDependencies(from: pair.root, to: pair.tree)
        #expect(!Self.exists(".build/checkouts/dep/Package.swift", in: pair.tree))
    }
}
