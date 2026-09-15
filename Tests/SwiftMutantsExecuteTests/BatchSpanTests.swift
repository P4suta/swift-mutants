// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsInstrument
import Testing

@testable import SwiftMutantsExecute

/// Which bundles a batch spans, which is what it costs.
///
/// A batch used to cost one process, because a package used to build one test bundle. It
/// builds one per test target now, so a batch spanning three of them is three processes -
/// and a batch holding one mutant from each of two targets saves nothing at all while
/// looking exactly like a saving.
@Suite("Batches and the bundles they span")
struct BatchSpanTests {

    static func mutants() throws -> [InstrumentedMutant] { try SchedulerTests.mutants() }

    /// A batch used to cost one process. It now costs one per bundle it spans, because a
    /// package builds one test bundle per test target - so a batch of two mutants in two
    /// different targets costs two processes and saves nothing at all.
    ///
    /// Reported from a package with twenty-five bundles holding 1346 tests, several of
    /// them under fifteen: batching across the small ones cost almost as many processes as
    /// running the mutants alone would have.
    @Test("prefers mutants that live in the same bundle")
    func groupsWithinABundle() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(
            byMutant: [
                // Two in Core, one in App. A greedy that took the first disjoint group
                // would put Core and App together and leave the second Core mutant alone -
                // two batches spanning three bundles between them.
                mutants[0].index: ["CoreTests.S/a()"],
                mutants[1].index: ["AppTests.S/b()"],
                mutants[2].index: ["CoreTests.S/c()"],
            ],
        )
        let batches = Batch.group(Array(mutants.prefix(3)), using: coverage)
        let spans = batches.map { batch in
            Set(batch.tests.compactMap { $0.split(separator: ".").first.map(String.init) })
        }
        #expect(spans.allSatisfy { $0.count == 1 }, "\(spans)")
        // The two Core mutants share a process; App has its own.
        #expect(batches.count == 2)
        #expect(Set(batches.map(\.mutants.count)) == [2, 1])
    }

    /// A mutant whose tests span two bundles is not the same scheduling problem as one
    /// whose tests span one, and it does not join their batch: its batch would cost two
    /// processes where theirs costs one, and every member of theirs would be paying for it.
    @Test("keeps a mutant that spans two bundles out of a batch that spans one")
    func spansAreNotMixed() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(
            byMutant: [
                mutants[0].index: ["CoreTests.S/a()"],
                // Shares a test with the first, so it cannot join that group; and it is
                // the only other Core mutant, so there is no same-bundle group to take it.
                mutants[1].index: ["CoreTests.S/a()", "AppTests.S/b()"],
            ],
        )
        let batches = Batch.group(Array(mutants.prefix(2)), using: coverage)
        #expect(batches.count == 2)
    }
}

/// How many processes a run says it will take.
///
/// The number is the saving, countable in advance, and it was "one unit, one process"
/// while a package built one test bundle. A package builds one per test target now, so a
/// unit spanning three of them starts three - and a count that had not noticed would
/// understate every run in the flattering direction, making batching look like a larger
/// saving than it is.
@Suite("Counting the processes a run will take")
struct ProcessSpanTests {

    static func scheduler(coverage: Coverage?, bundles: Int) throws -> Scheduler {
        Scheduler(
            host: { _, _ in ScriptedHost() },
            jobs: 1,
            coverage: coverage,
            bundleCount: bundles
        )
    }

    @Test("counts one process per bundle a batch spans")
    func perBundle() throws {
        let mutants = try BatchSpanTests.mutants()
        let coverage = Coverage(
            byMutant: [
                mutants[0].index: ["CoreTests.S/a()"],
                mutants[1].index: ["CoreTests.S/b()"],
                mutants[2].index: ["AppTests.S/c()"],
            ],
        )
        // Two batches: the Core pair in one process, the App mutant in another.
        let scheduler = try Self.scheduler(coverage: coverage, bundles: 2)
        #expect(scheduler.processes(for: Array(mutants.prefix(3))) == 2)
    }

    /// A mutant nothing reaches is answered without starting anything, which is the
    /// saving this number exists to show.
    @Test("counts nothing for a mutant no test reaches")
    func unreachedCostsNothing() throws {
        let mutants = try BatchSpanTests.mutants()
        let coverage = Coverage(byMutant: [mutants[0].index: ["CoreTests.S/a()"]])
        let scheduler = try Self.scheduler(coverage: coverage, bundles: 3)
        #expect(scheduler.processes(for: Array(mutants.prefix(2))) == 1)
    }

    /// Without coverage any test might be the one that notices, so every mutant faces
    /// every bundle - and that is the bill a run without a probe actually pays.
    @Test("counts every bundle for every mutant when nothing was probed")
    func withoutCoverage() throws {
        let mutants = try BatchSpanTests.mutants()
        let scheduler = try Self.scheduler(coverage: nil, bundles: 4)
        #expect(scheduler.processes(for: Array(mutants.prefix(3))) == 12)
    }
}

/// A host that answers nothing, for tests that only count.
private struct ScriptedHost: MutantHost {
    func run(
        waking indices: [UInt32], onlyTests: [String]?, settling: StreamWatcher.Settlement
    ) async -> Verdict {
        Verdict(
            outcome: .survived,
            killedBy: [],
            firstFailure: nil,
            startedTests: [],
            durationMilliseconds: 0,
            termination: .exited(0)
        )
    }

    func probe(_ test: String, writingTo log: URL) async -> Int? { nil }
}
