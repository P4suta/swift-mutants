// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

/// A survivor the compiler proves could never have been caught, on a real package.
///
/// The unit tests settle what a fingerprint ignores and what a set of them means. What they
/// cannot settle is whether a run finds one - and the failure mode is a report that says
/// somebody's tests have a hole where there is none, which costs their afternoon rather
/// than a machine's.
@Suite("Proving equivalence, on a real package")
struct EquivalenceIntegrationTests {

    /// A package with one mutant that cannot be caught and one that can.
    ///
    /// `scale` is `value + 0`. The `add-to-sub` mutant makes it `value - 0`, and the
    /// optimiser turns both into `value` - so no test will ever tell them apart, measured
    /// on this toolchain. `atLeast` is a real decision and its mutants are real findings.
    ///
    /// Not every arithmetic identity works: `value * 1` folds to `value` and `value / 1`
    /// does not, so `mul-to-div` on `value * 1` is a genuine change. Which ones fold is a
    /// fact about the optimiser, which is the whole reason to ask it rather than reason
    /// about it.
    static func fixture() throws -> RunIntegrationTests.Fixture {
        let fixture = try RunIntegrationTests.fixture()
        try RunIntegrationTests.write(
            """
            public func scale(_ value: Int) -> Int {
                return value + 0
            }

            public func atLeast(_ value: Int, _ limit: Int) -> Bool {
                return value >= limit
            }
            """, to: fixture.root.appending(path: "Sources/Subject/Subject.swift"))
        try RunIntegrationTests.write(
            """
            import Testing
            @testable import Subject

            @Suite("Subject")
            struct SubjectTests {
                @Test("scales") func scales() { #expect(scale(3) == 3) }
                @Test("holds at the boundary") func boundary() { #expect(atLeast(3, 3)) }
            }
            """, to: fixture.root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))
        return fixture
    }

    static func run(
        _ fixture: RunIntegrationTests.Fixture, provingEquivalence: Bool
    ) async throws -> RunOutcome {
        try? FileManager.default.removeItem(at: fixture.workspace)
        try FileManager.default.createDirectory(
            at: fixture.workspace, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.execution.jobs = 4
        configuration.execution.provesEquivalence = provingEquivalence
        configuration.cache.mode = .disabled
        configuration.test.timeout = .seconds(180)
        return try await Run(
            root: fixture.root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            workspace: fixture.workspace
        ).run(environment: RunIntegrationTests.environment())
    }

    /// The whole claim: a mutant nothing could catch stops being reported as one nothing
    /// caught.
    @Test("takes a mutant nothing could catch out of the survivors", .tags(.integration))
    func findsAnEquivalent() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let plain = try await Self.run(fixture, provingEquivalence: false)
        let proved = try await Self.run(fixture, provingEquivalence: true)

        #expect(plain.summary.equivalent == 0, "it found one without being asked")
        #expect(proved.summary.equivalent > 0, "it found none when asked")
        #expect(proved.summary.survived < plain.summary.survived)

        // And the ones it proved are gone from the survivors, not merely relabelled twice.
        #expect(
            proved.results.count { $0.verdict.outcome == .equivalent }
                == plain.summary.survived - proved.summary.survived)
    }

    /// A mutant taken out of the survivors is out of the score's denominator too - it is
    /// not a hole in anybody's tests, and counting it as one makes every score wrong.
    @Test("leaves an equivalent mutant out of the score", .tags(.integration))
    func changesTheScore() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let plain = try await Self.run(fixture, provingEquivalence: false)
        let proved = try await Self.run(fixture, provingEquivalence: true)

        let plainScore = try #require(plain.summary.score.value)
        let provedScore = try #require(proved.summary.score.value)
        #expect(provedScore > plainScore)
    }

    /// And the mutants it says nothing about say the same thing they did.
    @Test("leaves every other answer alone", .tags(.integration))
    func leavesTheRest() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let plain = try await Self.run(fixture, provingEquivalence: false)
        let proved = try await Self.run(fixture, provingEquivalence: true)

        let before = Dictionary(
            uniqueKeysWithValues: plain.results.map { ($0.identity, $0.verdict.outcome) })
        for result in proved.results where result.verdict.outcome != .equivalent {
            #expect(result.verdict.outcome == before[result.identity])
        }
    }
}
