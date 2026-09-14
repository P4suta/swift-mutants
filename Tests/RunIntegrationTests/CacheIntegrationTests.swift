// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCache
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsReport
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Synchronization
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
        _ fixture: RunIntegrationTests.Fixture,
        mode: CacheMode = .auto,
        progress: @escaping @Sendable (RunStage) -> Void = { _ in }
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
        ).run(environment: RunIntegrationTests.environment(), progress: progress)
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

/// Not asking a test what it reaches when nothing it reaches has changed.
///
/// The probe is one process per test, so on a package of any size it is hundreds of
/// launches - and what a test runs changes only when the code it runs changes. The danger
/// is the same as for outcomes and so is the answer: remember what it rests on, and check.
@Suite("Remembering what a test runs, between runs")
struct ProbeMemoryIntegrationTests {

    static func forget(_ fixture: RunIntegrationTests.Fixture) {
        try? FileManager.default.removeItem(at: OutcomeCache.location(for: fixture.root))
        try? FileManager.default.removeItem(at: ProbeMemory.location(for: fixture.root))
    }

    /// Two runs, and the second asks nothing - then gives the same answers, which is the
    /// only thing that makes the first half worth having.
    @Test("asks nothing the second time, and answers the same", .tags(.integration))
    func asksNothingTheSecondTime() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        let first = try await CacheIntegrationTests.run(fixture)

        let seen = Mutex<(known: Int, total: Int)?>(nil)
        let second = try await CacheIntegrationTests.run(fixture) { stage in
            if case .recalled(let known, let total) = stage {
                seen.withLock { $0 = (known, total) }
            }
        }

        let found = try #require(
            seen.withLock { $0 }, "the second run never said what it recalled")
        #expect(found.known == found.total, "asked \(found.total - found.known) again")
        #expect(found.total > 0)
        #expect(
            CacheIntegrationTests.outcomes(second) == CacheIntegrationTests.outcomes(first))
    }

    /// The premise: the first run does ask, so the second one saving it is a difference.
    @Test("asks everything the first time", .tags(.integration))
    func asksEverythingTheFirstTime() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        let seen = Mutex<(known: Int, total: Int)?>(nil)
        _ = try await CacheIntegrationTests.run(fixture) { stage in
            if case .recalled(let known, let total) = stage {
                seen.withLock { $0 = (known, total) }
            }
        }
        #expect(seen.withLock { $0 } == nil, "it recalled something on a clean machine")
    }

    /// And the direction that matters. The code a test runs changed, so what it runs has to
    /// be established again.
    @Test("asks again when the code a test runs changed", .tags(.integration))
    func askingAgainAfterAChange() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer {
            fixture.cleanUp()
            Self.forget(fixture)
        }
        Self.forget(fixture)

        _ = try await CacheIntegrationTests.run(fixture)
        try RunIntegrationTests.write(
            """
            public func atLeast(_ value: Int, _ limit: Int) -> Bool {
                return value >= limit
            }

            public func eitherWay(_ left: Bool, _ right: Bool) -> Bool {
                return left && right
            }
            """ + "\npublic func third(_ value: Int) -> Int { value * 2 }\n",
            to: fixture.root.appending(path: "Sources/Subject/Subject.swift"))

        let seen = Mutex<(known: Int, total: Int)?>(nil)
        _ = try await CacheIntegrationTests.run(fixture) { stage in
            if case .recalled(let known, let total) = stage {
                seen.withLock { $0 = (known, total) }
            }
        }
        let recalled = seen.withLock { $0 }
        #expect(recalled == nil, "it recalled \(recalled?.known ?? 0) after the code changed")
    }
}
