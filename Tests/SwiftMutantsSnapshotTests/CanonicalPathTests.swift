// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsSnapshot

/// One spelling of a path, so that nothing has to reconcile two.
///
/// This has cost this project twice. Once when every compiler diagnostic in a run belonged
/// to no file, because the compiler said `/private/var/...` and the catalogue said
/// `/var/...`; and once when a build failed with `module '_DarwinFoundation1' is defined in
/// both`, naming the same file by both names, because a typecheck and a build reached the
/// same module cache by different routes.
@Suite("Canonical paths")
struct CanonicalPathTests {

    struct Fixture {
        let base: URL
        let real: URL
        let link: URL
        func cleanUp() { try? FileManager.default.removeItem(at: base) }
    }

    static func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-canonical-\(UUID().uuidString)")
        let real = base.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("let a = 1".utf8).write(to: real.appending(path: "A.swift"))
        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return Fixture(base: base, real: real, link: link)
    }

    @Test("gives two names for one file the same answer")
    func agreesOnOneFile() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let through = fixture.link.appending(path: "A.swift")
        let direct = fixture.real.appending(path: "A.swift")
        #expect(through.path != direct.path, "the fixture must offer two names")
        #expect(CanonicalPath.of(through) == CanonicalPath.of(direct))
    }

    /// The reason this exists rather than `resolvingSymlinksInPath()`: on macOS that
    /// normalises `/private/var` towards `/var`, which is the opposite of what the C
    /// library reports - and the C library is what the compiler records.
    @Test("agrees with the operating system about a temporary directory")
    func agreesWithTheSystem() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let canonical = try #require(CanonicalPath.of(fixture.real.path))
        // Whatever the platform's answer is, it is the same one `pwd -P` gives.
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "cd '\(fixture.real.path)' && pwd -P"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let said = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()

        #expect(canonical == said)
    }

    /// A path with no answer keeps the name it had. A run asks about directories it is
    /// about to create, and refusing them would be refusing the ordinary case.
    @Test("leaves a path that does not exist as it found it")
    func leavesTheUnknownAlone() {
        let nowhere = URL(filePath: "/swift-mutants-nothing-is-here/tree")
        #expect(CanonicalPath.of(nowhere) == nowhere)
        #expect(CanonicalPath.of(nowhere.path) == nil)
    }

    @Test("changes nothing about a name that is already the answer")
    func leavesACanonicalNameAlone() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let canonical = try #require(CanonicalPath.of(fixture.real.path))
        #expect(CanonicalPath.of(canonical) == canonical)
    }
}
