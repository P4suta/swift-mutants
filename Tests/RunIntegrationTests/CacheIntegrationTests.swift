// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCache
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

/// Answering a mutant without running it, and being right.
///
/// The largest saving a mutation tool has is not executing the mutants whose answer cannot
/// have changed, and the way it goes wrong is silent: `survived` comes back for a mutant a
/// test now catches, and the score goes up while the tests got no better. So these are
/// about correctness first - the same answers, and different answers when something that
/// matters changed - and only then about the saving.
@Suite("Remembering between runs")
struct CacheIntegrationTests {

    static func run(
        _ fixture: RunIntegrationTests.Fixture, mode: CacheMode = .auto
    ) async throws -> RunOutcome {
        try? FileManager.default.removeItem(at: fixture.workspace)
        try FileManager.default.createDirectory(
            at: fixture.workspace, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.execution.jobs = 4
        configuration.test.timeout = .seconds(180)
        configuration.cache.mode = mode
        return try await Run(
            root: fixture.root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            workspace: fixture.workspace
        ).run(environment: RunIntegrationTests.environment())
    }

    /// Nothing of the user's is written to, so the answers live in their cache directory -
    /// and a test that left them there would change the next test's answer.
    static func forget(_ fixture: RunIntegrationTests.Fixture) {
        try? FileManager.default.removeItem(at: OutcomeCache.location(for: fixture.root))
    }

    static func outcomes(_ outcome: RunOutcome) -> [MutantIdentity: Outcome] {
        Dictionary(
            uniqueKeysWithValues: outcome.results.map { ($0.identity, $0.verdict.outcome) })
    }

    /// The whole claim: run it twice, get the same answers, and get them without running
    /// anything the second time.
    @Test("gives the same answers the second time, without asking again", .tags(.integration))
    func sameAnswersWithoutAsking() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        let first = try await Self.run(fixture)
        let second = try await Self.run(fixture)

        #expect(Self.outcomes(second) == Self.outcomes(first))
        #expect(!first.results.isEmpty)
        #expect(second.summary.cached == second.results.count)
        #expect(first.summary.cached == 0)

        // And the second report says the same things about coverage. A remembered
        // survivor reported as unreachable would send somebody to delete working code.
        #expect(second.summary.uncovered == first.summary.uncovered)
        #expect(second.summary.survived == first.summary.survived)
    }

    /// And the rows are in the same order, so a report does not change shape because a
    /// cache happened to be warm.
    @Test("puts the answers back in the order they belong in", .tags(.integration))
    func keepsCatalogueOrder() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        let first = try await Self.run(fixture)
        let second = try await Self.run(fixture)
        #expect(second.results.map(\.identity) == first.results.map(\.identity))
    }

    /// Changing the code the tests run has to throw the answers away. This is the direction
    /// that matters: keeping one here is a wrong score.
    @Test("asks again when the code its tests run changed", .tags(.integration))
    func codeChangeInvalidates() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        _ = try await Self.run(fixture)
        try RunIntegrationTests.write(
            """
            public func atLeast(_ value: Int, _ limit: Int) -> Bool {
                return value >= limit
            }

            public func eitherWay(_ left: Bool, _ right: Bool) -> Bool {
                return left && right
            }

            public func added(_ value: Int) -> Int { value + 1 }
            """, to: fixture.root.appending(path: "Sources/Subject/Subject.swift"))

        let second = try await Self.run(fixture)
        #expect(second.summary.cached == 0, "something was remembered")
    }

    /// The case a cache built on coverage alone gets wrong. The code is untouched; only a
    /// test changed - and what a test concludes rests on the test.
    @Test("asks again when only a test changed", .tags(.integration))
    func testChangeInvalidates() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        let first = try await Self.run(fixture)
        try RunIntegrationTests.write(
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
                    #expect(!eitherWay(true, false))
                }
            }
            """, to: fixture.root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        let second = try await Self.run(fixture)
        #expect(second.summary.cached == 0, "something was remembered")
        // And the new assertion catches what the old one did not, which is the point of
        // noticing at all.
        let before = Self.outcomes(first).filter { $0.value == .survived }.count
        let after = Self.outcomes(second).filter { $0.value == .survived }.count
        #expect(after < before, "the new test caught nothing")
    }

    /// Turning it off means off: nothing is read and nothing is written.
    @Test("asks everything again when it is told to", .tags(.integration))
    func offMeansOff() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        _ = try await Self.run(fixture)
        let second = try await Self.run(fixture, mode: .disabled)
        #expect(second.summary.cached == 0)
    }

    /// A run with the cache off leaves no answers behind for the next one.
    @Test("writes nothing down when it is told not to", .tags(.integration))
    func offWritesNothing() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        _ = try await Self.run(fixture, mode: .disabled)
        #expect(OutcomeCache.read(from: OutcomeCache.location(for: fixture.root)).isEmpty)
    }
}
