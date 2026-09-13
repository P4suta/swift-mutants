// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

/// The tool's one claim, put to a real package end to end.
///
/// Everything else in this repository tests a piece. This runs the whole thing on a package
/// written for the purpose - one function whose two branches are tested, one whose branch is
/// not - and asks whether the answer is the one a person would give by reading it.
///
/// A mutation testing tool that got this wrong would be worse than none: it would tell
/// somebody their tests were fine when they were not.
@Suite("A whole run, on a real package")
struct RunIntegrationTests {

    struct Fixture {
        let root: URL
        let workspace: URL
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    /// A package with a tested comparison and an untested one.
    ///
    /// `atLeast` is exercised at both sides of its boundary, so shifting `>=` to `>` must be
    /// caught. `eitherWay` is only ever called with both arguments true, so dropping either
    /// operand changes nothing any test can see - and must be reported as surviving.
    static func fixture() throws -> Fixture {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-run-\(identifier)")
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-work-\(identifier)")

        try write(
            """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "Subject",
                targets: [
                    .target(name: "Subject"),
                    .testTarget(name: "SubjectTests", dependencies: ["Subject"]),
                ]
            )
            """, to: root.appending(path: "Package.swift"))

        try write(
            """
            public func atLeast(_ value: Int, _ limit: Int) -> Bool {
                return value >= limit
            }

            public func eitherWay(_ left: Bool, _ right: Bool) -> Bool {
                return left && right
            }
            """, to: root.appending(path: "Sources/Subject/Subject.swift"))

        try write(
            """
            import Testing
            @testable import Subject

            @Suite("Subject")
            struct SubjectTests {
                @Test("holds at the boundary") func boundary() {
                    #expect(atLeast(3, 3))
                    #expect(!atLeast(2, 3))
                }
                @Test("is true when both are") func both() {
                    #expect(eitherWay(true, true))
                }
            }
            """, to: root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        return Fixture(root: root, workspace: workspace)
    }

    static func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    static func environment() -> [String: String] {
        let ambient = ProcessInfo.processInfo.environment
        return ["HOME", "PATH", "DEVELOPER_DIR", "TMPDIR", "SDKROOT"]
            .reduce(into: [:]) { kept, name in kept[name] = ambient[name] }
    }

    static func run(_ fixture: Fixture) async throws -> RunOutcome {
        try FileManager.default.createDirectory(
            at: fixture.workspace, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.execution.jobs = 4
        configuration.test.timeout = .seconds(180)
        return try await Run(
            root: fixture.root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            workspace: fixture.workspace
        ).run(environment: Self.environment())
    }

    /// The answer a person would give by reading the package.
    @Test("catches what the tests cover and reports what they do not", .tags(.integration))
    func findsTheHole() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let outcome = try await Self.run(fixture)

        // The instrumented tree with nothing awake behaves like the one that was written.
        #expect(outcome.baseline.outcome == .survived)

        let byRule = Dictionary(
            grouping: outcome.results, by: { $0.rule.name }
        ).mapValues { $0.map(\.verdict.outcome) }

        // `>=` shifted to `>` breaks `atLeast(3, 3)`, which a test checks.
        #expect(byRule["ge-to-gt"] == [.killed], "\(byRule)")

        // Dropping either operand of `left && right` changes nothing the one test can see,
        // because it only ever passes two trues.
        #expect(byRule["and-keep-lhs"] == [.survived], "\(byRule)")
        #expect(byRule["and-keep-rhs"] == [.survived], "\(byRule)")

        // Every mutant got an answer, and none of them errored.
        #expect(outcome.summary.errored == 0, "\(outcome.summary)")
        #expect(outcome.summary.total == outcome.results.count + outcome.rejected.count)
        #expect(outcome.summary.killed > 0)
        #expect(outcome.summary.survived > 0)
    }

    /// The first invariant of the whole family: the tree a run was pointed at is not
    /// written to. Everything happens in a copy.
    @Test("leaves the package it was pointed at exactly as it found it", .tags(.integration))
    func readsOnly() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let before = try Self.fingerprint(fixture.root)
        _ = try await Self.run(fixture)
        let after = try Self.fingerprint(fixture.root)
        #expect(before == after)
    }

    /// Every path in the tree, with the digest of every file.
    static func fingerprint(_ root: URL) throws -> [String: Int] {
        var found: [String: Int] = [:]
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        for path in paths.sorted() {
            let file = root.appending(path: path)
            let bytes = (try? Data(contentsOf: file)) ?? Data()
            found[path] = bytes.hashValue
        }
        return found
    }

    /// A score is an answer about a program, so a tree that does not behave like the one
    /// the user wrote must stop the run rather than produce one.
    @Test("refuses to score a package whose own tests fail", .tags(.integration))
    func redBaseline() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        try Self.write(
            """
            import Testing
            @testable import Subject

            @Suite("Subject")
            struct SubjectTests {
                @Test("is wrong") func wrong() { #expect(atLeast(1, 3)) }
            }
            """, to: fixture.root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        let failure = await #expect(throws: RunError.self) { try await Self.run(fixture) }
        #expect(failure?.description.contains("does not behave like the one you wrote") == true)
    }

    @Test("says so when there is nothing to mutate", .tags(.integration))
    func nothingToMutate() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        try Self.write(
            "public func greet() -> String { return \"hello\" }",
            to: fixture.root.appending(path: "Sources/Subject/Subject.swift"))
        try Self.write(
            """
            import Testing
            @testable import Subject

            @Suite("Subject")
            struct SubjectTests {
                @Test("greets") func greets() { #expect(greet() == "hello") }
            }
            """, to: fixture.root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        let failure = await #expect(throws: RunError.self) { try await Self.run(fixture) }
        #expect(failure?.description.contains("nothing to mutate") == true)
    }
}

extension Tag {
    /// Needs a real Swift toolchain.
    @Tag static var integration: Self
}
