// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsReport
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

/// Splitting a catalogue across machines, on a real package.
///
/// The unit tests settle that a share is a function of the mutant. What they cannot settle
/// is whether a run actually measures only its own - and the failure mode is quiet: a shard
/// that measured everything would give the right answers and waste four machines, and one
/// that measured nothing would give a score of `N/A` that somebody might read as zero.
@Suite("Sharding a real run")
struct ShardIntegrationTests {

    /// One share of three. Refusing here would be a bug in the fixture rather than a fact
    /// about the code, so it says so and stops.
    static func share(_ index: Int) -> Shard {
        guard let shard = Shard(index, of: 3) else { fatalError("malformed fixture share") }
        return shard
    }

    static func run(
        _ fixture: RunIntegrationTests.Fixture, shard: Shard?
    ) async throws -> RunOutcome {
        try? FileManager.default.removeItem(at: fixture.workspace)
        try FileManager.default.createDirectory(
            at: fixture.workspace, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.execution.jobs = 4
        configuration.execution.shard = shard
        configuration.cache.mode = .disabled
        configuration.test.timeout = .seconds(180)
        return try await Run(
            root: fixture.root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            workspace: fixture.workspace
        ).run(environment: RunIntegrationTests.environment())
    }

    /// Every mutant is measured by exactly one share, and together they are the run.
    @Test("measures each mutant on exactly one machine", .tags(.integration))
    func eachMutantOnce() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let whole = try await Self.run(fixture, shard: nil)
        var measured: [MutantIdentity: Outcome] = [:]
        var seen: [MutantIdentity: Int] = [:]

        for index in 1...3 {
            let piece = try await Self.run(fixture, shard: Self.share(index))
            #expect(piece.results.count == whole.results.count, "a share lost a row")
            for result in piece.results where result.verdict.outcome != .notRun {
                measured[result.identity] = result.verdict.outcome
                seen[result.identity, default: 0] += 1
            }
        }

        #expect(seen.count == whole.results.count, "\(seen.count) of \(whole.results.count)")
        #expect(seen.values.allSatisfy { $0 == 1 }, "something was measured twice")
        #expect(
            measured
                == Dictionary(
                    uniqueKeysWithValues: whole.results.map { ($0.identity, $0.verdict.outcome) }))
    }

    /// And a share really is a share: one machine of three does not do all the work.
    @Test("leaves the other machines something to do", .tags(.integration))
    func doesLessThanEverything() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let piece = try await Self.run(fixture, shard: Self.share(1))
        let mine = piece.results.count { $0.verdict.outcome != .notRun }
        #expect(mine > 0, "it measured nothing")
        #expect(mine < piece.results.count, "it measured everything")
        #expect(piece.summary.notRun == piece.results.count - mine)
    }
}

/// Three machines, and one answer.
///
/// The whole point of a share is that the pieces go back together. This runs the split and
/// the merge against a real package and asks the only question that matters: does the
/// merged answer equal the one machine that did all of it would have given?
@Suite("Sharding and merging")
struct ShardMergeIntegrationTests {

    @Test("merges three shares into the answer one machine would give", .tags(.integration))
    func roundTrips() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let whole = RunReport(of: try await ShardIntegrationTests.run(fixture, shard: nil))
        var shares: [RunReport] = []
        for index in 1...3 {
            shares.append(
                RunReport(
                    of: try await ShardIntegrationTests.run(
                        fixture, shard: ShardIntegrationTests.share(index))))
        }

        let merged = try #require(SwiftMutantsReport.Merge.of(shares))

        #expect(merged.summary.killed == whole.summary.killed)
        #expect(merged.summary.survived == whole.summary.survived)
        #expect(merged.summary.uncovered == whole.summary.uncovered)
        #expect(merged.summary.notRun == 0, "something was measured by nobody")
        #expect(merged.summary.score.value == whole.summary.score.value)

        // And every mutant says the same thing it said when one machine did all of it.
        let asOne = Dictionary(uniqueKeysWithValues: whole.mutants.map { ($0.id, $0.outcome) })
        let asThree = Dictionary(uniqueKeysWithValues: merged.mutants.map { ($0.id, $0.outcome) })
        #expect(asThree == asOne)

        // The tests a survivor faced survive the renumbering.
        for mutant in merged.mutants where mutant.outcome == "survived" {
            #expect(mutant.ran.allSatisfy { merged.tests.indices.contains($0) })
            #expect(mutant.ran.count == mutant.testsStarted)
        }
    }
}
