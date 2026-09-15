// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsInstrument
import SwiftMutantsBuild
import Testing

@testable import SwiftMutantsExecute

/// Putting several mutants in one process without losing track of which is which.
///
/// The remaining waste in a run is the process itself: loading a test bundle costs what it
/// costs whether one test runs or forty. A package with good locality spends most of a run
/// starting processes rather than running tests - two thousand mutants at five tests each
/// is ten thousand test executions and two thousand launches, and if a launch costs what
/// twenty tests cost, the launches are five times the bill.
///
/// Sound because of one rule: no test reaches two mutants in a batch. That is what makes a
/// failing test name exactly one of them.
@Suite("Batches")
struct BatchTests {

    static func mutants() throws -> [InstrumentedMutant] { try SchedulerTests.mutants() }

    @Test("puts mutants nothing shares a test with into one process")
    func groupsDisjointMutants() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(
            byMutant: [
                mutants[0].index: ["a"],
                mutants[1].index: ["b"],
                mutants[2].index: ["c"],
            ],
        )
        let batches = Batch.group(Array(mutants.prefix(3)), using: coverage)
        #expect(batches.count == 1)
        #expect(batches[0].mutants.count == 3)
        #expect(batches[0].tests.sorted() == ["a", "b", "c"])
    }

    /// The rule, and the whole reason a batch is safe.
    @Test("keeps mutants that share a test apart")
    func separatesOverlappingMutants() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(
            byMutant: [
                mutants[0].index: ["a", "shared"],
                mutants[1].index: ["b", "shared"],
            ],
        )
        let batches = Batch.group(Array(mutants.prefix(2)), using: coverage)
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.mutants.count == 1 })
    }

    @Test("names the one mutant a failing test was about")
    func attributesAFailure() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(
            byMutant: [mutants[0].index: ["a"], mutants[1].index: ["b"]],
        )
        let batch = try #require(Batch.group(Array(mutants.prefix(2)), using: coverage).first)
        #expect(batch.mutant(killedBy: "a") == mutants[0].index)
        #expect(batch.mutant(killedBy: "b") == mutants[1].index)
    }

    /// A name nobody claims is not guessed at. Crediting a kill to whoever happens to be
    /// nearby is how a tool reports a survivor as caught.
    @Test("says nothing about a test that belongs to no one")
    func unknownTest() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(byMutant: [mutants[0].index: ["a"]])
        let batch = try #require(Batch.group([mutants[0]], using: coverage).first)
        #expect(batch.mutant(killedBy: "elsewhere") == nil)
    }

    /// A bound rather than a target: a batch that grows without one turns a single crash
    /// into a re-run of everything.
    @Test("does not grow past the limit it was given")
    func respectsTheLimit() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.enumerated().map { ($1.index, ["t\($0)"]) }),
        )
        let batches = Batch.group(mutants, using: coverage, limit: 2)
        #expect(batches.allSatisfy { $0.mutants.count <= 2 })
        #expect(batches.count == (mutants.count + 1) / 2)
    }

    /// A mutant nothing reaches has no business in a process at all.
    @Test("leaves out a mutant nothing reaches")
    func skipsUnreached() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(byMutant: [mutants[0].index: ["a"]])
        let batches = Batch.group(mutants, using: coverage)
        #expect(batches.flatMap { $0.mutants }.map(\.index) == [mutants[0].index])
    }

    /// The same package must produce the same batches, or two runs cannot be compared.
    @Test("groups the same way every time")
    func deterministic() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.enumerated().map { ($1.index, ["t\($0 % 3)"]) }),
        )
        let first = Batch.group(mutants, using: coverage).map { $0.mutants.map(\.index) }
        let again = Batch.group(mutants, using: coverage).map { $0.mutants.map(\.index) }
        #expect(first == again)
    }

    @Test("holds an empty catalogue")
    func empty() {
        #expect(Batch.group([], using: Coverage(byMutant: [:])).isEmpty)
    }
}

/// Running a batch and handing each of its mutants the answer about itself.
@Suite("Batched runs")
struct BatchedRunTests {

    static func mutants() throws -> [InstrumentedMutant] { try SchedulerTests.mutants() }

    static func scheduler(_ fake: ScriptedBundle.Fake) -> Scheduler {
        Scheduler(
            bundles: TestBundles(plans: [fake.plan]),
            runner: SchedulerTests.runner(),
            scratch: fake.scratch,
            timeout: .seconds(30),
            jobs: 1
        )
    }

    /// Three answers from one process, each about the right mutant.
    @Test("gives every mutant in a batch its own answer")
    func answersEachMutant() async throws {
        let mutants = try Self.mutants()
        // The middle one is caught; the others are not.
        let fake = try ScriptedBundle.fake(
            failingFor: [], failingTests: ["b": "b"])
        defer { fake.cleanUp() }

        let coverage = Coverage(
            byMutant: [
                mutants[0].index: ["a"],
                mutants[1].index: ["b"],
                mutants[2].index: ["c"],
            ],
        )
        let batch = try #require(Batch.group(Array(mutants.prefix(3)), using: coverage).first)
        let results = try #require(
            await Self.scheduler(fake).results(of: batch, worker: 0))

        #expect(results.count == 3)
        let killed = results.filter { $0.verdict.outcome == .killed }
        #expect(killed.map(\.identity) == [mutants[1].identity])
        #expect(killed.first?.verdict.killedBy == ["b"])
        #expect(results.filter { $0.verdict.outcome == .survived }.count == 2)
    }

    /// Two of three caught, in one process. A batch that stopped at the first failure
    /// would answer one mutant and guess about the other two - which is the whole thing a
    /// batch must not do.
    @Test("answers every mutant when more than one is caught")
    func answersSeveralKills() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(
            failingFor: [], failingTests: ["a": "a", "c": "c"])
        defer { fake.cleanUp() }

        let coverage = Coverage(
            byMutant: [
                mutants[0].index: ["a"],
                mutants[1].index: ["b"],
                mutants[2].index: ["c"],
            ],
        )
        let batch = try #require(Batch.group(Array(mutants.prefix(3)), using: coverage).first)
        let results = try #require(
            await Self.scheduler(fake).results(of: batch, worker: 0))

        let killed = Set(results.filter { $0.verdict.outcome == .killed }.map(\.identity))
        #expect(killed == [mutants[0].identity, mutants[2].identity])
        #expect(
            results.filter { $0.verdict.outcome == .survived }.map(\.identity)
                == [mutants[1].identity])
    }

    /// A failure from a test nobody in the batch owns means the batch was built wrong.
    /// Crediting it to whoever happens to be nearby is how a survivor is reported as
    /// caught, so the batch is abandoned and the caller asks one at a time.
    @Test("refuses a failure that belongs to nobody")
    func refusesAnUnclaimedFailure() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [], failingWhatever: "P.S/stranger()")
        defer { fake.cleanUp() }

        let coverage = Coverage(byMutant: [mutants[0].index: ["a"]])
        let batch = try #require(Batch.group([mutants[0]], using: coverage).first)
        #expect(
            await Self.scheduler(fake).results(of: batch, worker: 0)
                == nil)
    }

    /// Nothing caught: every mutant in the batch survives, and one process said so.
    @Test("survives them all when nothing fails")
    func allSurvive() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        let coverage = Coverage(
            byMutant: [mutants[0].index: ["a"], mutants[1].index: ["b"]])
        let batch = try #require(Batch.group(Array(mutants.prefix(2)), using: coverage).first)
        let results = try #require(
            await Self.scheduler(fake).results(of: batch, worker: 0))
        #expect(results.allSatisfy { $0.verdict.outcome == .survived })
    }

    /// A batch that crashed or ran out of time says nothing about any of its mutants, and
    /// the caller has to ask them one at a time rather than share out a guess.
    @Test("refuses to share out an answer it did not get")
    func refusesOnTrouble() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [], neverStarting: true)
        defer { fake.cleanUp() }

        let coverage = Coverage(byMutant: [mutants[0].index: ["a"]])
        let batch = try #require(Batch.group([mutants[0]], using: coverage).first)
        #expect(
            await Self.scheduler(fake).results(of: batch, worker: 0)
                == nil)
    }
}

/// Batching through the scheduler, where the saving actually happens.
@Suite("Batched scheduling")
struct BatchedSchedulingTests {

    static func mutants() throws -> [InstrumentedMutant] { try SchedulerTests.mutants() }

    static func scheduler(_ fake: ScriptedBundle.Fake, coverage: Coverage?) -> Scheduler {
        Scheduler(
            bundles: TestBundles(plans: [fake.plan]),
            runner: SchedulerTests.runner(),
            scratch: fake.scratch,
            timeout: .seconds(30),
            jobs: 1,
            coverage: coverage
        )
    }

    /// Six mutants, six disjoint tests, one process. Counted from the bundle's own record
    /// rather than from the scheduler's account of itself.
    @Test("runs a batch in one process instead of one each")
    func oneProcessForMany() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.enumerated().map { ($1.index, ["t\($0)"]) }),
        )
        let results = await Self.scheduler(fake, coverage: coverage)
            .run(mutants)

        #expect(results.count == mutants.count)
        let invocations = try String(
            contentsOf: fake.scratch.appending(path: "argv.txt"), encoding: .utf8
        ).split(separator: "\n").count
        #expect(invocations == 1, "started \(invocations) processes for \(mutants.count) mutants")
    }

    /// And the answers are the ones a run without batching gives.
    @Test("gives the same answers as running them one at a time")
    func sameAnswers() async throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.enumerated().map { ($1.index, ["t\($0)"]) }),
        )

        let batched = try ScriptedBundle.fake(failingFor: [], failingTests: ["t2": "t2"])
        defer { batched.cleanUp() }
        let together = await Self.scheduler(batched, coverage: coverage)
            .run(mutants)

        let apart = try ScriptedBundle.fake(failingFor: [], failingTests: ["t2": "t2"])
        defer { apart.cleanUp() }
        let alone = await Scheduler(
            bundles: TestBundles(plans: [apart.plan]),
            runner: SchedulerTests.runner(),
            scratch: apart.scratch,
            timeout: .seconds(30),
            jobs: 1,
            coverage: coverage
        ).offering(nil).run(mutants)

        #expect(together.map(\.identity) == alone.map(\.identity))
        #expect(together.first { $0.verdict.outcome == .killed }?.identity == mutants[2].identity)
    }

    /// Results come back in catalogue order however the batches were arranged, or a report
    /// changes shape for a reason nobody can act on.
    @Test("reports in catalogue order whatever the batching did")
    func keepsTheOrder() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        // The first two share a test and the rest do not, so the greedy grouping puts
        // the second mutant in a batch of its own *after* the batch holding the others -
        // and flattening the batches in the order they finish is not catalogue order.
        var sets: [UInt32: [String]] = [:]
        for (position, mutant) in mutants.enumerated() {
            sets[mutant.index] = position <= 1 ? ["shared"] : ["u\(position)"]
        }
        let coverage = Coverage(byMutant: sets)
        let results = await Self.scheduler(fake, coverage: coverage)
            .run(mutants)
        #expect(results.map(\.identity) == mutants.map(\.identity))
    }

    /// Two mutants the same test reaches are both caught by it. They cannot share a
    /// process, because a batch can only credit a failing test to one mutant - so forcing
    /// them together reports one of them as surviving a test that catches it, which is the
    /// dangerous direction: a hole nobody is told about.
    @Test("catches both mutants a shared test reaches")
    func sharedTestCatchesBoth() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [], failingTests: ["shared": "shared"])
        defer { fake.cleanUp() }

        let pair = Array(mutants.prefix(2))
        let coverage = Coverage(
            byMutant: Dictionary(uniqueKeysWithValues: pair.map { ($0.index, ["shared"]) }),
        )
        let results = await Self.scheduler(fake, coverage: coverage)
            .run(pair)

        #expect(results.count == 2)
        #expect(
            results.allSatisfy { $0.verdict.outcome == .killed },
            "\(results.map { ($0.rule.name, $0.verdict.outcome) })")
    }

    /// A batch that cannot be shared out is asked again one at a time, and every mutant
    /// still gets an answer. Dropping them would lose mutants silently, which is worse
    /// than the slow path the fallback costs.
    @Test("asks one at a time when a batch cannot be shared out")
    func fallsBackToOneAtATime() async throws {
        let mutants = try Self.mutants()
        // A failure from a test nobody in the batch owns.
        let fake = try ScriptedBundle.fake(failingFor: [], failingWhatever: "P.S/stranger()")
        defer { fake.cleanUp() }

        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.enumerated().map { ($1.index, ["t\($0)"]) }),
        )
        let results = await Self.scheduler(fake, coverage: coverage)
            .run(mutants)

        #expect(results.count == mutants.count)
        #expect(results.map(\.identity) == mutants.map(\.identity))
    }

    /// Nothing to batch with is not a failure: without coverage every mutant is its own
    /// unit, because "unknown" means "possibly every test".
    @Test("runs one at a time when nothing is known")
    func noCoverageMeansNoBatches() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        _ = await Self.scheduler(fake, coverage: nil).run(mutants)
        let invocations = try String(
            contentsOf: fake.scratch.appending(path: "argv.txt"), encoding: .utf8
        ).split(separator: "\n").count
        #expect(invocations == mutants.count)
    }
}
