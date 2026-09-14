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

/// Measuring what somebody just wrote, rather than everything they have.
///
/// A whole-package run is `Θ(mutants)` however clever the scheduling, and on a package of
/// any size that is not something anybody puts in a pre-push hook. A run scoped to the
/// files somebody touched is `Θ(mutants in those files)` - and unlike a cache of verdicts
/// it makes no claim about what it did not run.
@Suite("Scoped runs, on a real package")
struct ScopeTests {

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

    /// A package in a repository, with one file committed and one file changed after.
    static func committedFixture() throws -> RunIntegrationTests.Fixture {
        let fixture = try RunIntegrationTests.fixture()
        try RunIntegrationTests.write(
            "public func first(_ a: Int, _ b: Int) -> Bool { return a >= b }",
            to: fixture.root.appending(path: "Sources/Subject/First.swift"))
        try RunIntegrationTests.write(
            """
            import Testing
            @testable import Subject

            @Suite("Subject")
            struct SubjectTests {
                @Test("first holds at the boundary") func firstBoundary() {
                    #expect(first(3, 3))
                    #expect(!first(2, 3))
                }
                @Test("holds at the boundary") func boundary() {
                    #expect(atLeast(3, 3))
                    #expect(!atLeast(2, 3))
                }
                @Test("is true when both are") func both() {
                    #expect(eitherWay(true, true))
                }
            }
            """, to: fixture.root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        try Self.git(["init", "-q", "-b", "main"], in: fixture.root)
        try Self.git(["config", "user.email", "t@example.com"], in: fixture.root)
        try Self.git(["config", "user.name", "Test"], in: fixture.root)
        try Self.git(["config", "commit.gpgsign", "false"], in: fixture.root)
        try Self.git(["add", "."], in: fixture.root)
        try Self.git(["commit", "-q", "-m", "first"], in: fixture.root)
        return fixture
    }

    static func run(
        _ fixture: RunIntegrationTests.Fixture, changedSince reference: String?
    )
        async throws -> RunOutcome
    {
        // A workspace of its own, because a snapshot refuses a destination that already
        // holds something - which is right, and which a test running twice has to respect.
        let workspace = fixture.workspace
            .deletingLastPathComponent()
            .appending(path: "swift-mutants-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.execution.jobs = 2
        return try await Run(
            root: fixture.root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            workspace: workspace,
            changedSince: reference
        ).run(environment: RunIntegrationTests.environment())
    }

    /// The whole point: a mutant in an untouched file is not measured, and one in the file
    /// that changed is.
    @Test("measures the file that changed and not the others", .tags(.integration))
    func measuresOnlyWhatChanged() async throws {
        let fixture = try Self.committedFixture()
        defer { fixture.cleanUp() }

        // Touch one file after the commit.
        try RunIntegrationTests.write(
            "public func first(_ a: Int, _ b: Int) -> Bool { return a > b || a == b }",
            to: fixture.root.appending(path: "Sources/Subject/First.swift"))

        let scoped = try await Self.run(fixture, changedSince: "HEAD")
        #expect(scoped.scope == .changed(since: "HEAD", files: 1))
        #expect(
            Set(scoped.results.map { $0.path.rendered }) == ["Sources/Subject/First.swift"],
            "\(Set(scoped.results.map { $0.path.rendered }))"
        )

        // The whole package holds strictly more, which is what makes the scope worth having.
        let everything = try await Self.run(fixture, changedSince: nil)
        #expect(everything.scope == .everything)
        #expect(everything.results.count > scoped.results.count)
    }

    /// Nothing to measure is an answer, not a crash and not a silent hundred per cent.
    @Test("says so when nothing has changed", .tags(.integration))
    func nothingChanged() async throws {
        let fixture = try Self.committedFixture()
        defer { fixture.cleanUp() }

        let failure = await #expect(throws: RunError.self) {
            try await Self.run(fixture, changedSince: "HEAD")
        }
        #expect(failure?.description.contains("nothing to mutate") == true)
    }

    /// A reference nobody has is a mistake worth a sentence, not a run that quietly
    /// measures nothing and reports full marks.
    @Test("says so when the reference does not exist", .tags(.integration))
    func unknownReference() async throws {
        let fixture = try Self.committedFixture()
        defer { fixture.cleanUp() }

        let failure = await #expect(throws: RunError.self) {
            try await Self.run(fixture, changedSince: "no-such-reference")
        }
        #expect(failure?.description.contains("git diff") == true, "\(failure as Any)")
    }
}
