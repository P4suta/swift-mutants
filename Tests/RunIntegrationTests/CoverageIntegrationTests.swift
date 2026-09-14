// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsTrace
import Synchronization
import Testing

/// Offering each mutant the tests that reach it, on a real package.
@Suite("Coverage, on a real package")
struct CoverageIntegrationTests {

    static func fixture() throws -> RunIntegrationTests.Fixture {
        try RunIntegrationTests.fixture()
    }

    static func write(_ contents: String, to file: URL) throws {
        try RunIntegrationTests.write(contents, to: file)
    }

    static func environment() -> [String: String] { RunIntegrationTests.environment() }

    /// A mutant is offered the tests that reach it, not the suite.
    ///
    /// This is the difference between `Θ(mutants × tests)` and `Θ(mutants × the few that
    /// matter)`, and it is the kind of thing that can be right in a helper and absent from
    /// the pipeline - which is what happened to the deadline, so it is checked here
    /// through a real run rather than by calling the helper.
    @Test("offers each mutant only the tests that reach it", .tags(.integration))
    func usesCoverage() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        // A third test that touches nothing the other two do, so the suite is strictly
        // larger than what any mutant needs.
        try Self.write(
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
                @Test("has nothing to do with any of it") func unrelated() {
                    #expect(1 + 1 == 2)
                }
            }
            """, to: fixture.root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        let seen = Mutex<(uncovered: Int, average: Double)?>(nil)
        try FileManager.default.createDirectory(
            at: fixture.workspace, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.execution.jobs = 2

        let outcome = try await Run(
            root: fixture.root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            workspace: fixture.workspace
        ).run(environment: Self.environment()) { stage in
            if case .covered(let uncovered, let average) = stage {
                seen.withLock { $0 = (uncovered, average) }
            }
        }

        let found = try #require(seen.withLock { $0 }, "the run never said what it covered")
        // Three tests in the suite, and no mutant needs all three.
        #expect(found.average > 0)
        #expect(found.average < 3, "a mutant faced \(found.average) of 3 tests")

        // The survivor ran its whole (filtered) set, and the unrelated test was not in
        // it. That is the saving, observed rather than inferred from a count.
        let survivor = try #require(outcome.results.first { $0.rule.name == "and-keep-lhs" })
        #expect(survivor.verdict.outcome == .survived)
        #expect(!survivor.verdict.startedTests.isEmpty)
        #expect(
            !survivor.verdict.startedTests.contains { $0.contains("unrelated") },
            "it ran \(survivor.verdict.startedTests)"
        )

        // And the answer is the one a run without coverage gives.
        let byRule = Dictionary(
            grouping: outcome.results, by: { $0.rule.name }
        ).mapValues { $0.map(\.verdict.outcome) }
        #expect(byRule["ge-to-gt"] == [.killed], "\(byRule)")
    }
}
