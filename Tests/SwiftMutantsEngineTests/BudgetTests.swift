// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsExecute
import Testing

@testable import SwiftMutantsEngine

/// Turning what a run measured into how long one mutant gets.
///
/// A number picked out of the air is either so tight that a loaded machine reports a
/// working suite as a hang, or so loose that a mutant which really does hang costs the
/// whole budget. The only things that tell them apart are how long this suite takes when
/// nothing is wrong with it, and how much of it the mutant in question actually faces.
///
/// The first failure this prevents was measured on this repository: 592 mutants, 82
/// deadlines, 0 survivors reported, and a score of 100% that was not true of anything. A
/// killed mutant stops at the first test that notices; a surviving one runs everything -
/// so the mutants that meet a deadline are overwhelmingly the survivors, and a deadline
/// counted as a detection turns every one of them into a kill.
///
/// The second was measured on somebody else's: 898 seconds handed to a mutant that faces
/// 45 of 1333 tests, because the budget was five times the whole suite whatever coverage
/// had just said. Fifteen minutes to establish that a trial finishing in under one had not
/// hung.
@Suite("Deadlines")
struct BudgetTests {

    static func baseline(taking milliseconds: Int, tests: Int = 10) -> Verdict {
        Verdict(
            outcome: .survived,
            killedBy: [],
            firstFailure: nil,
            startedTests: (1...max(tests, 1)).map { "P.S/t\($0)()" },
            durationMilliseconds: milliseconds,
            termination: .exited(0)
        )
    }

    /// A mutant nothing narrowed still faces the whole suite, and still gets several times
    /// what the whole suite costs.
    @Test("gives a mutant facing everything several times what the suite takes")
    func multiplesOfTheBaselineWhenFacingEverything() {
        let budget = Run.budget(
            from: Self.baseline(taking: 20_000), cheapestTrial: nil, asked: nil)
        #expect(budget.forTrial(bundles: 1, tests: nil) == .seconds(100))
    }

    /// The change this suite exists for. Coverage is the tool's largest saving and it used
    /// to be spent in one direction only: a mutant ran the few tests that reach it and was
    /// then given the budget of all of them.
    @Test("gives a mutant facing a tenth of the suite far less than one facing all of it")
    func narrowMutantsGetLess() {
        let budget = Run.budget(
            from: Self.baseline(taking: 100_000, tests: 100), cheapestTrial: nil, asked: nil)
        let all = budget.forTrial(bundles: 1, tests: nil)
        let few = budget.forTrial(bundles: 1, tests: 10)
        #expect(few < all)
        #expect(all == .seconds(500))
        // A tenth of the tests, so a tenth of the work, plus whatever the floor insists on.
        #expect(few == .seconds(50))
    }

    /// A suite that takes no time at all still needs a deadline a loaded machine can meet.
    @Test("never gives less than half a minute", arguments: [0, 1, 100, 5_000])
    func floor(milliseconds: Int) {
        let budget = Run.budget(
            from: Self.baseline(taking: milliseconds), cheapestTrial: nil, asked: nil)
        #expect(budget.forTrial(bundles: 1, tests: nil) >= .seconds(30))
        #expect(budget.forTrial(bundles: 1, tests: 1) >= .seconds(30))
    }

    /// Long suites get proportionally long deadlines rather than the floor.
    @Test("grows with the suite rather than sitting at the floor")
    func growsWithTheSuite() {
        let short = Run.budget(
            from: Self.baseline(taking: 10_000), cheapestTrial: nil, asked: nil)
        let long = Run.budget(
            from: Self.baseline(taking: 60_000), cheapestTrial: nil, asked: nil)
        #expect(long.forTrial(bundles: 1, tests: nil) > short.forTrial(bundles: 1, tests: nil))
        #expect(long.forTrial(bundles: 1, tests: nil) == .seconds(300))
    }

    /// What the probe measured is the part of a trial that does not depend on how many
    /// tests run. Without it a narrow mutant is charged only for its tests, which will not
    /// start a process - so every one of them would meet its deadline and be retried
    /// serially, turning a parallel run into a sequential one.
    @Test("charges a narrow mutant for the process as well as for its tests")
    func interceptProtectsTheNarrowCase() {
        let withCost = Run.budget(
            from: Self.baseline(taking: 100_000, tests: 1_000),
            cheapestTrial: 2_000,
            asked: nil
        )
        let withoutCost = Run.budget(
            from: Self.baseline(taking: 100_000, tests: 1_000),
            cheapestTrial: nil,
            asked: nil
        )
        // Facing one test: two seconds of process plus almost nothing, against almost
        // nothing at all. Both land on the floor here, which is the floor doing its job -
        // but the whole-suite budget must be the same either way, because the suite's
        // total is what was measured and the split does not change it.
        #expect(withCost.forTrial(bundles: 1, tests: nil) == .seconds(500))
        #expect(withoutCost.forTrial(bundles: 1, tests: nil) == .seconds(500))
        #expect(
            withCost.forTrial(bundles: 1, tests: 200)
                > withoutCost.forTrial(bundles: 1, tests: 200))
    }

    /// An explicit `--timeout` is an answer. Deriving something else from their suite
    /// would be overruling somebody quietly.
    @Test("hands back what was asked for, whatever the suite did")
    func askedForWins() {
        let budget = Run.budget(
            from: Self.baseline(taking: 100_000), cheapestTrial: 2_000, asked: .seconds(7))
        #expect(budget.forTrial(bundles: 1, tests: nil) == .seconds(7))
        #expect(budget.forTrial(bundles: 4, tests: 1) == .seconds(7))
    }
}
