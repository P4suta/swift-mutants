// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsReport
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsCLI

/// The file and the mutant these tests are about.
enum PatchFixture {

    static let source = "func f(_ a: Int, _ b: Int) -> Bool {\n    a < b\n}\n"

    static func mutant() -> RunReport.Mutant {
        RunReport.Mutant(
            id: String(repeating: "a", count: 64),
            path: "Sources/Codec/Header.swift",
            line: .init(2),
            column: .init(7),
            span: RunReport.Span(start: 43, end: 44),
            rule: "lt-to-le@1",
            original: "<",
            replacement: "<=",
            outcome: "survived",
            killedBy: [],
            ran: [],
            testsStarted: 0,
            attempts: 1,
            durationMilliseconds: 1
        )
    }
}

/// A patch is only a patch if the thing that applies patches accepts it.
///
/// Everything above is about the text. This is about whether `git apply` takes it, reverts
/// it, and refuses it when the file has moved - which is the only question that matters,
/// and the only one this tool cannot answer by reading its own output.
@Suite("A patch a real git accepts")
struct PatchApplicationTests {

    struct Fixture {
        let root: URL
        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        func file(_ path: String) throws -> String {
            try String(contentsOf: root.appending(path: path), encoding: .utf8)
        }
    }

    static func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-patch-\(UUID().uuidString)")
        let file = root.appending(path: "Sources/Codec/Header.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(PatchFixture.source.utf8).write(to: file)
        return Fixture(root: root)
    }

    /// `git apply` with no repository, which is what somebody debugging one mutant has.
    @discardableResult
    static func git(_ arguments: [String], in root: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("applies, and makes exactly the change it said it would", .tags(.integration))
    func applies() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let patch = try #require(Patch.of(PatchFixture.mutant(), in: PatchFixture.source))
        let file = fixture.root.appending(path: "mutant.patch")
        try Data(patch.utf8).write(to: file)

        #expect(try Self.git(["apply", "mutant.patch"], in: fixture.root) == 0)
        #expect(try fixture.file("Sources/Codec/Header.swift").contains("a <= b"))
    }

    /// The other half of being able to try something: putting it back.
    @Test("reverts, and leaves the file as it was", .tags(.integration))
    func reverts() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let patch = try #require(Patch.of(PatchFixture.mutant(), in: PatchFixture.source))
        let file = fixture.root.appending(path: "mutant.patch")
        try Data(patch.utf8).write(to: file)

        #expect(try Self.git(["apply", "mutant.patch"], in: fixture.root) == 0)
        #expect(try Self.git(["apply", "-R", "mutant.patch"], in: fixture.root) == 0)
        #expect(try fixture.file("Sources/Codec/Header.swift") == PatchFixture.source)
    }

    /// And the safety property, enforced by git rather than by this tool: a patch made for
    /// one file does not apply to a different one.
    @Test("does not apply to a file that has moved on", .tags(.integration))
    func refusesAMovedFile() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let patch = try #require(Patch.of(PatchFixture.mutant(), in: PatchFixture.source))
        try Data(patch.utf8).write(to: fixture.root.appending(path: "mutant.patch"))
        try Data("func f() -> Bool { true }\n".utf8)
            .write(to: fixture.root.appending(path: "Sources/Codec/Header.swift"))

        #expect(try Self.git(["apply", "mutant.patch"], in: fixture.root) != 0)
    }
}
