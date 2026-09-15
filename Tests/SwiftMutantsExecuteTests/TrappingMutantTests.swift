// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsCore
import SwiftMutantsInstrument
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsExecute

/// A mutant that takes the process down with it.
///
/// Bounds arithmetic is where mutation testing earns its keep, and a mutation to bounds
/// arithmetic traps: `body[..<(n - tag)]` becomes `body[..<(n + tag)]` and the array bounds
/// check fires. That is the strongest kill there is - the mutant did not change an answer,
/// it destroyed the program - and the process dies on a signal *without writing a failure
/// event*, because there is no assertion, only a trap.
///
/// One mutant on its own is answered correctly: the process exited non-zero, and non-zero
/// with tests having started is a kill.
///
/// A **batch** was not. Several mutants run in one process, and the answer is shared out by
/// which test failed - so a process that died with no failing test had nothing to share out,
/// and every mutant in it came back `survived`. Reported from a package of two hand-written
/// binary codecs, reproduced by hand in two files with two different rules, where `explain`
/// said "3 tests ran with this change in and all of them passed" about a change that crashes
/// the test process.
///
/// Silent, and flattering in the direction that costs somebody an afternoon: a survivor
/// whose missing assertion cannot be written, because the assertion it wants is "the process
/// is still alive".
@Suite("A mutant that traps")
struct TrappingMutantTests {

    static func batch(_ mutants: [InstrumentedMutant], using coverage: Coverage) -> Batch {
        guard let batch = Batch.group(mutants, using: coverage, limit: 8).first else {
            fatalError("the fixture produced no batch")
        }
        return batch
    }

    static func scheduler(_ fake: ScriptedBundle.Fake, coverage: Coverage?) -> Scheduler {
        Scheduler(
            bundles: TestBundles(plans: [fake.plan]),
            runner: Runner(recorder: TraceRecorder()),
            scratch: fake.scratch,
            timeout: .seconds(30),
            jobs: 1,
            coverage: coverage
        )
    }

    /// Alone, which has always been right and has to stay right.
    @Test("is killed when it is the only mutant in its process")
    func killedAlone() async throws {
        let mutants = try SchedulerTests.mutants()
        let fake = try SchedulerTests.fake(failingFor: [], trapping: [mutants[0].index])
        defer { fake.cleanUp() }

        let results = await Self.scheduler(fake, coverage: nil)
            .run([mutants[0]])
        let said = results.first?.verdict.outcome
        #expect(said == .killed, "\(said as Any)")
    }

    /// And in company. A process that died without naming a failing test has nothing to
    /// share out, so its mutants are asked again one at a time rather than all credited
    /// with surviving something that killed the process they were in.
    @Test("is killed when it shared a process with others")
    func killedInABatch() async throws {
        let mutants = Array(try SchedulerTests.mutants().prefix(3))
        let fake = try SchedulerTests.fake(failingFor: [], trapping: [mutants[1].index])
        defer { fake.cleanUp() }

        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.enumerated().map { position, mutant in
                    (mutant.index, ["P.S/only\(position)()"])
                }))
        let results = await Self.scheduler(fake, coverage: coverage).run(mutants)

        #expect(results.count == mutants.count)
        let trapped = results.first { $0.identity == mutants[1].identity }
        #expect(
            trapped?.verdict.outcome == .killed,
            "\(trapped?.verdict.outcome as Any) after \(trapped?.verdict.termination as Any)")
    }

    /// And nobody else in the process is convicted by it. The others were in a program that
    /// died before their own tests could say anything, so what is owed them is another look
    /// rather than either verdict.
    @Test("does not make the rest of its process look guilty")
    func othersAreStillMeasured() async throws {
        let mutants = Array(try SchedulerTests.mutants().prefix(3))
        let fake = try SchedulerTests.fake(failingFor: [], trapping: [mutants[1].index])
        defer { fake.cleanUp() }

        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.enumerated().map { position, mutant in
                    (mutant.index, ["P.S/only\(position)()"])
                }))
        let results = await Self.scheduler(fake, coverage: coverage).run(mutants)

        for mutant in [mutants[0], mutants[2]] {
            let said = results.first { $0.identity == mutant.identity }?.verdict.outcome
            #expect(said == .survived, "\(said as Any)")
        }
    }
}
