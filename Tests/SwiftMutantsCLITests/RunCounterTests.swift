// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import Testing

@testable import SwiftMutantsCLI

/// How far through the mutants a run is.
///
/// A line per mutant would bury the handful a person can act on, and no line at all leaves
/// somebody watching a silent terminal for half an hour wondering whether it has hung. So:
/// counts, periodically - and counts that are true, which is the part that broke.
@Suite("Counting through a run")
struct RunCounterTests {

    static func result(_ outcome: Outcome) -> MutantResult {
        NarrationFixture.result(outcome, tests: ["P.S/a()"])
    }

    static func counter(_ stages: [RunStage]) -> (counter: RunCounter, said: [String]) {
        var counter = RunCounter()
        var said: [String] = []
        for stage in stages {
            if let line = counter.observe(stage) { said.append(line) }
        }
        return (counter, said)
    }

    @Test("counts what it is told, and says so at the end")
    func countsAndSays() {
        let found = Self.counter(
            [.running(total: 2, processes: 2)]
                + [.finished(Self.result(.killed)), .finished(Self.result(.survived))])
        #expect(found.counter.done == 2)
        #expect(found.said.last?.contains("2/2") == true)
        #expect(found.said.last?.contains("1 killed") == true)
        #expect(found.said.last?.contains("1 survived") == true)
    }

    /// The bug this exists for. `.running` says how many mutants still have to be *run*,
    /// and every mutant is finished whether it ran or was remembered - so a warm run used
    /// to count to six hundred and seventy-six out of nought.
    @Test("counts against the whole catalogue when some were remembered")
    func countsAgainstTheCatalogue() {
        let found = Self.counter(
            [.remembered(known: 2, total: 3), .running(total: 1, processes: 1)]
                + Array(repeating: RunStage.finished(Self.result(.killed)), count: 3))
        #expect(found.counter.total == 3)
        #expect(found.said.last?.contains("3/3") == true)
    }

    /// A run that remembered everything runs nothing, and still counts to the right number.
    @Test("counts against the whole catalogue when everything was remembered")
    func countsWhenNothingRuns() {
        let found = Self.counter(
            [.remembered(known: 3, total: 3), .running(total: 0, processes: 0)]
                + Array(repeating: RunStage.finished(Self.result(.survived)), count: 3))
        #expect(found.counter.total == 3)
        #expect(found.said.last?.contains("3/3") == true)
        #expect(found.said.last?.contains("/0") == false)
    }

    /// And a cold run has only `.running` to go on, which is then the whole catalogue.
    @Test("takes the total from the running line when nothing was remembered")
    func coldRunTakesTheRunningTotal() {
        let found = Self.counter([.running(total: 4, processes: 4)])
        #expect(found.counter.total == 4)
    }

    /// Often enough to show movement on a small package, rare enough not to scroll a large
    /// one away - and always at the end, whatever the arithmetic.
    @Test("says something every so often, and at the end")
    func saysPeriodically() {
        let found = Self.counter(
            [.running(total: 30, processes: 30)]
                + Array(repeating: RunStage.finished(Self.result(.killed)), count: 30))
        #expect(found.said.count == 2)
        #expect(found.said.first?.contains("25/30") == true)
        #expect(found.said.last?.contains("30/30") == true)
    }

    /// Everything else a run says is somebody else's line.
    @Test("says nothing about a phase that is not about mutants")
    func saysNothingElse() {
        #expect(Self.counter([.snapshotting, .building, .baseline]).said.isEmpty)
    }
}
