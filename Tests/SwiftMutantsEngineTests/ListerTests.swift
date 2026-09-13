// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsEngine

/// The one command that answers without building anything.
///
/// `list` is the fast path a person reaches for before agreeing to let a run take an hour,
/// and it is the only command that still answers while the package does not compile. So it
/// reads the package's description, reads the files that description names, and stops.
@Suite("Lister")
struct ListerTests {

    /// A package on disk, and a `swift` scripted to describe it.
    struct Fixture {
        let root: URL
        let fake: FakeToolchain
        func cleanUp() {
            fake.cleanUp()
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func fixture(_ files: [String: String], describing targets: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-lister-\(UUID().uuidString)")
        for (path, contents) in files {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
        let described = targets.replacingOccurrences(of: "$ROOT", with: root.path)
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "package", "describe"],
                standardOutput: #"{"name":"Example","targets":[\#(described)]}"#
            )
        ])
        return Fixture(root: root, fake: fake)
    }

    static func list(
        _ fixture: Fixture, configuration: Configuration = Configuration()
    ) async throws
        -> Listing
    {
        try await Lister(
            root: fixture.root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            executable: "\(fixture.fake.pathEntry)/swift"
        ).list(environment: fixture.fake.environment)
    }

    @Test("finds the mutants in the files the package names")
    func findsMutants() async throws {
        let fixture = try Self.fixture(
            [
                "Sources/Core/Compare.swift":
                    "func f(_ a: Int, _ b: Int) -> Bool { return a < b }",
                "Sources/Core/Flags.swift": "let enabled = true",
            ],
            describing: """
                {"name":"Core","type":"library","path":"$ROOT/Sources/Core",
                 "sources":["Compare.swift","Flags.swift"]}
                """
        )
        defer { fixture.cleanUp() }

        let listing = try await Self.list(fixture)
        #expect(listing.filesRead == 2)
        #expect(
            listing.catalog.mutants.map(\.rule.name).sorted() == ["lt-to-le", "true-to-false"]
        )
    }

    /// A file the package does not compile must not be mutated: the mutants would be ones
    /// nothing can kill, and the score would be quietly dragged down by them.
    @Test("reads only the files the package says it has")
    func readsOnlyWhatThePackageNames() async throws {
        let fixture = try Self.fixture(
            [
                "Sources/Core/Compare.swift": "func f(_ a: Int, _ b: Int) -> Bool { a < b }",
                "Sources/Core/Excluded.swift": "func g(_ a: Int, _ b: Int) -> Bool { a > b }",
            ],
            describing: """
                {"name":"Core","type":"library","path":"$ROOT/Sources/Core",
                 "sources":["Compare.swift"]}
                """
        )
        defer { fixture.cleanUp() }

        let listing = try await Self.list(fixture)
        #expect(listing.filesRead == 1)
        #expect(listing.catalog.mutants.map(\.rule.name) == ["lt-to-le"])
    }

    @Test("obeys the patterns a configuration gives it")
    func obeysConfiguration() async throws {
        let fixture = try Self.fixture(
            [
                "Sources/Core/Compare.swift": "func f(_ a: Int, _ b: Int) -> Bool { a < b }",
                "Sources/Core/Generated.swift": "func g(_ a: Int, _ b: Int) -> Bool { a > b }",
            ],
            describing: """
                {"name":"Core","type":"library","path":"$ROOT/Sources/Core",
                 "sources":["Compare.swift","Generated.swift"]}
                """
        )
        defer { fixture.cleanUp() }

        var configuration = Configuration()
        configuration.mutation.exclude = [Glob("**/Generated.swift")].compactMap { $0 }

        let listing = try await Self.list(fixture, configuration: configuration)
        #expect(listing.catalog.mutants.map(\.rule.name) == ["lt-to-le"])
    }

    /// Mutating a test would measure whether the tests test themselves.
    @Test("leaves the test target alone")
    func leavesTestsAlone() async throws {
        let fixture = try Self.fixture(
            [
                "Sources/Core/Compare.swift": "func f(_ a: Int, _ b: Int) -> Bool { a < b }",
                "Tests/CoreTests/CompareTests.swift":
                    "func t(_ a: Int, _ b: Int) -> Bool { a > b }",
            ],
            describing: """
                {"name":"Core","type":"library","path":"$ROOT/Sources/Core","sources":["Compare.swift"]},
                {"name":"CoreTests","type":"test","path":"$ROOT/Tests/CoreTests","sources":["CompareTests.swift"]}
                """
        )
        defer { fixture.cleanUp() }

        let listing = try await Self.list(fixture)
        #expect(listing.filesRead == 1)
        #expect(listing.catalog.mutants.map(\.rule.name) == ["lt-to-le"])
    }

    /// The listing has to say where each mutant is in the words a person uses, which is the
    /// one conversion out of byte offsets in the whole tool.
    @Test("can say where each mutant is")
    func knowsWhereEachMutantIs() async throws {
        let fixture = try Self.fixture(
            ["Sources/Core/Compare.swift": "func f(_ a: Int, _ b: Int) -> Bool {\n    a < b\n}"],
            describing: """
                {"name":"Core","type":"library","path":"$ROOT/Sources/Core","sources":["Compare.swift"]}
                """
        )
        defer { fixture.cleanUp() }

        let listing = try await Self.list(fixture)
        let mutant = try #require(listing.catalog.mutants.first)
        let place = try #require(listing.positions[mutant.path]?.position(of: mutant.span.start))
        #expect(place.description == "2:7")
    }

    @Test("says what it passed over")
    func saysWhatItPassedOver() async throws {
        let fixture = try Self.fixture(
            ["Sources/Core/Compare.swift": "func f(_ a: Int, _ b: Int) { print(a < b) }"],
            describing: """
                {"name":"Core","type":"library","path":"$ROOT/Sources/Core","sources":["Compare.swift"]}
                """
        )
        defer { fixture.cleanUp() }

        let listing = try await Self.list(fixture)
        #expect(listing.catalog.mutants.isEmpty)
        #expect(listing.skips.map(\.skip.reason.rawValue) == ["arid"])
        #expect(listing.skips.first?.skip.candidatesHidden == 1)
    }

    /// The workspace is only ever read. `list` makes no copy because it changes nothing.
    @Test("writes nothing into the package it read")
    func writesNothing() async throws {
        let fixture = try Self.fixture(
            ["Sources/Core/Compare.swift": "func f(_ a: Int, _ b: Int) -> Bool { a < b }"],
            describing: """
                {"name":"Core","type":"library","path":"$ROOT/Sources/Core","sources":["Compare.swift"]}
                """
        )
        defer { fixture.cleanUp() }

        let before = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        _ = try await Self.list(fixture)
        let after = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        #expect(before == after)
    }

    @Test("holds a package with nothing in it")
    func emptyPackage() async throws {
        let fixture = try Self.fixture([:], describing: "")
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)

        let listing = try await Self.list(fixture)
        #expect(listing.catalog.mutants.isEmpty)
        #expect(listing.filesRead == 0)
    }
}
