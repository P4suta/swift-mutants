// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCache
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

/// Survivors a project wrote down, checked against a real run of a real package.
///
/// The unit tests fix what the arithmetic is. This fixes that the pipeline actually does
/// it - that the configuration reaches the check, that the check reaches the outcome, and
/// that a second run measures an expected mutant rather than answering it from the cache.
/// A helper that is right and unwired is the failure this whole tier exists to catch.
@Suite("Expectations, end to end")
struct ExpectationIntegrationTests {

    static func run(
        _ fixture: RunIntegrationTests.Fixture,
        expecting expectations: [Configuration.Expectation],
        mode: CacheMode = .auto
    ) async throws -> RunOutcome {
        try? FileManager.default.removeItem(at: fixture.workspace)
        try FileManager.default.createDirectory(
            at: fixture.workspace, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.execution.jobs = 4
        configuration.test.timeout = .seconds(180)
        configuration.cache.mode = mode
        configuration.mutation.expect = expectations
        return try await Run(
            root: fixture.root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            workspace: fixture.workspace
        ).run(environment: RunIntegrationTests.environment())
    }

    static func forget(_ fixture: RunIntegrationTests.Fixture) {
        try? FileManager.default.removeItem(at: OutcomeCache.location(for: fixture.root))
    }

    /// One survivor the fixture actually has, so the expectation is about a real mutant
    /// rather than a string this test made up.
    static func aSurvivor(of outcome: RunOutcome) throws -> String {
        let survivor = outcome.results.first { $0.verdict.outcome == .survived }
        return try #require(survivor).identity.rendered
    }

    @Test("counts a survivor the project wrote down", .tags(.integration))
    func countsAnExpectedSurvivor() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        let first = try await Self.run(fixture, expecting: [])
        let identity = try Self.aSurvivor(of: first)

        Self.forget(fixture)
        let second = try await Self.run(
            fixture,
            expecting: [
                Configuration.Expectation(identity: identity, reason: "cannot be observed")
            ])

        #expect(second.expectations.met == 1)
        #expect(second.expectations.isSatisfied)
        #expect(second.summary.expectedSurvivors == 1)
        // And it leaves the score's denominator, which is the point of writing it down.
        #expect(second.summary.score.undetected == second.summary.survived - 1)
    }

    /// The second run has a warm cache for everything. The expected mutant must still be
    /// measured: an expectation answered from last week is a claim nobody tested.
    @Test("measures an expected mutant even with a warm cache", .tags(.integration))
    func measuresDespiteTheCache() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        let first = try await Self.run(fixture, expecting: [])
        let identity = try Self.aSurvivor(of: first)
        let expectation = Configuration.Expectation(
            identity: identity, reason: "cannot be observed")

        // Everything else comes back from the cache; this one does not.
        let warm = try await Self.run(fixture, expecting: [expectation])
        #expect(warm.summary.cached == warm.results.count - 1)
        #expect(warm.expectations.met == 1)

        let measured = try #require(warm.results.first { $0.identity.rendered == identity })
        #expect(measured.attempts > 0)
    }

    /// An identity that is not in the catalogue is a note somebody is relying on that has
    /// stopped applying, and the run says so rather than passing.
    @Test("says an expectation about a mutant it does not have is stale", .tags(.integration))
    func staleIsReported() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        let outcome = try await Self.run(
            fixture,
            expecting: [
                Configuration.Expectation(
                    identity: Digest.of("no such mutant").hexadecimal,
                    reason: "was unreachable")
            ])
        #expect(outcome.expectations.stale.count == 1)
        #expect(!outcome.expectations.isSatisfied)
        #expect(outcome.expectations.stale.first?.reason == "was unreachable")
    }

    /// A mutant the tests do catch contradicts the note, which is the case an expectation
    /// exists to detect: somebody wrote the assertion and the configuration still says
    /// nothing can.
    @Test("says an expectation about a mutant something caught is wrong", .tags(.integration))
    func contradictionIsReported() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        let first = try await Self.run(fixture, expecting: [])
        let killed = try #require(first.results.first { $0.verdict.outcome == .killed })

        Self.forget(fixture)
        let second = try await Self.run(
            fixture,
            expecting: [
                Configuration.Expectation(
                    identity: killed.identity.rendered, reason: "nothing asserts on this")
            ])
        #expect(second.expectations.contradicted.count == 1)
        #expect(!second.expectations.isSatisfied)
        #expect(second.summary.expectedSurvivors == 0)
    }
}
