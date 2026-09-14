// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsInstrument
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsExecute

/// Counting the processes a catalogue will take, before any of them start.
///
/// A saving nobody can see is a saving nobody can check. The gap between the number of
/// mutants and the number of processes is what the coverage bought, and it is countable in
/// advance rather than inferred from a clock.
@Suite("Counting processes")
struct ProcessCountTests {

    static func mutants() throws -> [InstrumentedMutant] { try SchedulerTests.mutants() }

    static func scheduler(_ fake: ScriptedBundle.Fake, coverage: Coverage?) -> Scheduler {
        Scheduler(
            plan: fake.plan,
            runner: SchedulerTests.runner(),
            scratch: fake.scratch,
            timeout: .seconds(30),
            jobs: 1,
            coverage: coverage
        )
    }

    @Test("counts one process per mutant when nothing is known")
    func oneEach() throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }
        #expect(Self.scheduler(fake, coverage: nil).processes(for: mutants) == mutants.count)
    }

    @Test("counts one process for a batch")
    func oneForABatch() throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.enumerated().map { ($1.index, ["t\($0)"]) }),
        )
        #expect(Self.scheduler(fake, coverage: coverage).processes(for: mutants) == 1)
    }

    /// A mutant nothing reaches takes no process at all, which is the cheapest answer
    /// there is.
    @Test("counts no process for a mutant nothing reaches")
    func noneForUnreached() throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        let coverage = Coverage(byMutant: [mutants[0].index: ["a"]])
        #expect(Self.scheduler(fake, coverage: coverage).processes(for: mutants) == 1)
    }

    /// And the count is the truth: it is what the run actually starts.
    @Test("counts what the run really starts")
    func countMatchesReality() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        // Two groups, because half of them share a test with each other.
        var sets: [UInt32: [String]] = [:]
        for (position, mutant) in mutants.enumerated() {
            sets[mutant.index] = ["shared\(position % 2)", "u\(position)"]
        }
        let coverage = Coverage(byMutant: sets)
        let scheduler = Self.scheduler(fake, coverage: coverage)

        let expected = scheduler.processes(for: mutants)
        _ = await scheduler.run(mutants, in: SchedulerTests.path())
        let started = try String(
            contentsOf: fake.scratch.appending(path: "argv.txt"), encoding: .utf8
        ).split(separator: "\n").count
        #expect(started == expected, "said \(expected), started \(started)")
    }
}
