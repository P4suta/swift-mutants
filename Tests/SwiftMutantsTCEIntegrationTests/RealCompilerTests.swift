// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsTCE

/// The claim, asked of a real compiler.
///
/// Everything else about fingerprints is about what may be ignored, and can be settled
/// against text. This cannot: whether the Swift optimiser actually turns `x * 1` into `x`
/// is a fact about a toolchain, and the whole feature rests on it.
///
/// If this ever fails, the feature is wrong rather than the test - and better to be told
/// that by a test than by somebody who trusted an `equivalent` verdict.
@Suite("What the compiler really does")
struct RealCompilerTests {

    struct Fixture {
        let root: URL
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-tce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }

    /// The SIL of one file, optimised, as a fingerprint.
    static func fingerprint(of source: String, in fixture: Fixture) throws -> Digest {
        let file = fixture.root.appending(path: "Subject.swift")
        try Data(source.utf8).write(to: file)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [
            "swiftc", "-emit-sil", "-O", "-swift-version", "6",
            "-sdk", try Self.sdk(), "-module-name", "Subject", file.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let sil = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!sil.isEmpty)
        return Fingerprint.of(sil)
    }

    static func sdk() throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["xcrun", "--show-sdk-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole feature, in one assertion: a mutant that changes nothing about the program
    /// compiles to the same program, and one that changes something does not.
    @Test(
        "knows a mutant that changed nothing from one that changed something", .tags(.integration))
    func tellsThemApart() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let original = try Self.fingerprint(
            of: "public func scale(_ x: Int) -> Int { x * 1 }\n", in: fixture)
        let equivalent = try Self.fingerprint(
            of: "public func scale(_ x: Int) -> Int { x }\n", in: fixture)
        let real = try Self.fingerprint(
            of: "public func scale(_ x: Int) -> Int { x + 1 }\n", in: fixture)

        #expect(original == equivalent, "the optimiser no longer folds `x * 1`")
        #expect(original != real)
    }

    /// And it is not fooled by the file being a different length: the same program written
    /// with more of it above is the same program.
    @Test("is not fooled by the code moving down the file", .tags(.integration))
    func ignoresPosition() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let tight = try Self.fingerprint(
            of: "public func scale(_ x: Int) -> Int { x * 1 }\n", in: fixture)
        let spaced = try Self.fingerprint(
            of: "\n\n\n// a comment\npublic func scale(_ x: Int) -> Int { x }\n", in: fixture)
        #expect(tight == spaced)
    }
}

extension Tag {
    /// Drives a real toolchain.
    @Tag static var integration: Self
}
