// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsEngine

/// Reading one of a package's files, which is the whole of discovery's work.
///
/// It is a function of the file and the configuration and of nothing else - not of what
/// another file held, not of what was read before it. That is what lets a package's files
/// be read at once rather than one after another, and it is why this is testable without a
/// package to point it at: `list` needs `swift package describe` and a toolchain, and this
/// needs a directory with a file in it.
///
/// Three passes over every byte - a full-fidelity parse, an operator fold and a walk - done
/// one file at a time left every core but one idle through the command people reach for
/// precisely because it is the fast one.
@Suite("Reading one file")
struct ReadingAFileTests {

    static func package(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "swift-mutants-reading-\(UUID().uuidString)")
        for (name, body) in files {
            let path = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: path, atomically: true, encoding: .utf8)
        }
        return root
    }

    static func subject(_ name: String, mutable: Bool = true) throws -> Lister.Subject {
        guard let path = WorkspaceRelativePath(name) else {
            fatalError("malformed fixture path \(name)")
        }
        return Lister.Subject(path: path, isMutable: mutable)
    }

    static let everything = GlobSet(include: [], exclude: [])

    @Test("finds what is in a file it may mutate")
    func findsCandidates() throws {
        let root = try Self.package([
            "Sources/A/Subject.swift": "func f(_ a: Int, _ b: Int) -> Bool { a < b }"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let read = try #require(
            Lister.reading(
                try Self.subject("Sources/A/Subject.swift"),
                in: root,
                admitted: Self.everything,
                as: Configuration()))
        #expect(read.discovery?.candidates.isEmpty == false)
        #expect(read.positions != nil)
    }

    /// A file that is digested and not parsed. Both halves matter: the digest because what
    /// a test concludes rests on the test as much as on the code, and an answer remembered
    /// between runs has to rest on all of it; no discovery because a mutant in a test is a
    /// mutant in the thing doing the measuring.
    @Test("digests a file it may not mutate, and looks for nothing in it")
    func digestsWithoutParsing() throws {
        let root = try Self.package([
            "Tests/ATests/SubjectTests.swift": "func t(_ a: Int) -> Bool { a < 1 }"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let read = try #require(
            Lister.reading(
                try Self.subject("Tests/ATests/SubjectTests.swift", mutable: false),
                in: root,
                admitted: Self.everything,
                as: Configuration()))
        #expect(read.discovery == nil)
        #expect(read.positions == nil)
    }

    /// The C bug, kept nailed down. A target holding C is a `library` like any other, so
    /// its `.c` files arrive here as mutable - and swift-syntax reads `#define` and
    /// `#include` as macro expansions, which this tool skips. A package vendoring Argon2
    /// got 79 skips for somebody else's preprocessor, reported as findings about its code,
    /// and 365 mutants it was never told about.
    @Test("digests a C file without trying to read it as Swift")
    func doesNotParseC() throws {
        let root = try Self.package([
            "Sources/A/blake2.c": "#include <stdint.h>\nint f(int a) { return a < 1; }\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let read = try #require(
            Lister.reading(
                try Self.subject("Sources/A/blake2.c"),
                in: root,
                admitted: Self.everything,
                as: Configuration()))
        #expect(read.discovery == nil)
        #expect(read.digest == Digest.of("#include <stdint.h>\nint f(int a) { return a < 1; }\n"))
    }

    /// What the project excluded is still digested and still not read. Excluding a
    /// directory does not make its contents stop being part of what a test's conclusion
    /// rests on.
    @Test("digests a file the project excluded, and looks for nothing in it")
    func honoursTheSelection() throws {
        let root = try Self.package([
            "Sources/Generated/Big.swift": "func f(_ a: Int, _ b: Int) -> Bool { a < b }"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let excluded = try #require(Glob("Sources/Generated/**"))
        let read = try #require(
            Lister.reading(
                try Self.subject("Sources/Generated/Big.swift"),
                in: root,
                admitted: GlobSet(include: [], exclude: [excluded]),
                as: Configuration()))
        #expect(read.discovery == nil)
        #expect(read.digest != Digest.of(""))
    }

    /// The mutations a project wrote itself reach the file they name, which is the other
    /// half of the configuration actually being read.
    @Test("offers the file the mutations the project wrote for it")
    func carriesCustomMutants() throws {
        let root = try Self.package([
            "Sources/A/Subject.swift": "func f() -> Int { 1 }"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        var configuration = Configuration()
        configuration.mutation.custom = [
            Configuration.Custom(
                file: "Sources/A/Subject.swift",
                find: "1",
                replace: "2",
                reason: "the empty case counts as one, not two")
        ]
        let read = try #require(
            Lister.reading(
                try Self.subject("Sources/A/Subject.swift"),
                in: root,
                admitted: Self.everything,
                as: configuration))
        #expect(
            read.discovery?.candidates.contains { $0.replacement == "2" } == true,
            "\(read.discovery?.candidates.map(\.replacement) ?? [])")
    }

    /// A file the package lists and the filesystem does not have is nothing at all, not an
    /// empty one: an empty digest would go into what the next run's answers rest on and
    /// say the file had not changed when it had never been there.
    @Test("comes back with nothing for a file that is not there")
    func missingFile() throws {
        let root = try Self.package(["Sources/A/Present.swift": "let x = 1"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            Lister.reading(
                try Self.subject("Sources/A/Absent.swift"),
                in: root,
                admitted: Self.everything,
                as: Configuration()) == nil)
    }
}
