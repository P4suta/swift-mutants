// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsExecute

/// How long one mutant gets, given how much of the suite it actually faces.
///
/// This was one number for every mutant: five times the whole contended suite, floor of
/// thirty seconds, coverage not consulted at all. So a mutant reached by forty-five of a
/// package's 1333 tests got the same budget as a mutant nothing narrowed - reported from a
/// real package as 898 seconds for a trial that runs 3.4% of the suite. Fifteen minutes to
/// find out that a mutant which finishes in under one did not hang.
///
/// The shape is an intercept and a slope, and the reason is structural rather than
/// measured: a trial's cost has a part that does not depend on how many tests run - start
/// the process, load the bundle - and a part that does. Pure proportion gets the small
/// cases catastrophically wrong, because `baseline / everyTest` will not start a process,
/// let alone load a bundle; every narrow mutant would then meet its deadline, be retried
/// serially, and turn a parallel run into a sequential one.
///
/// The intercept is paid per bundle rather than per trial, now that a package builds one
/// test bundle per test target and a mutant may face several.
@Suite("A deadline for one mutant")
struct MutantBudgetTests {

    /// A suite of a thousand tests taking a hundred seconds, where a trial that runs
    /// almost nothing costs two.
    static let derived = Budget.derived(
        fixedMilliseconds: 2_000,
        perTestMilliseconds: 98,
        everyTest: 1_000,
        slack: 5,
        floor: .seconds(30)
    )

    /// What the old single number was, and what a mutant nothing narrows still gets.
    @Test("gives a mutant that faces everything what the whole suite costs, with slack")
    func facingEverything() {
        // 2000 + 98 * 1000 = 100_000ms, times five.
        #expect(Self.derived.forTrial(bundles: 1, tests: nil) == .milliseconds(500_000))
    }

    /// The point of the whole thing.
    @Test("gives a mutant that faces a handful far less")
    func facingAHandful() {
        // 2000 + 98 * 10 = 2980ms, times five is under the floor, so the floor.
        #expect(Self.derived.forTrial(bundles: 1, tests: 10) == .seconds(30))
        // 2000 + 98 * 100 = 11_800ms, times five is 59s, which clears it.
        #expect(Self.derived.forTrial(bundles: 1, tests: 100) == .milliseconds(59_000))
    }

    /// A budget below the floor is a loaded machine reporting a working suite as a hang.
    @Test("never gives less than the floor", arguments: [0, 1, 5, 20])
    func floorHolds(tests: Int) {
        #expect(Self.derived.forTrial(bundles: 1, tests: tests) >= .seconds(30))
    }

    /// The intercept is per bundle. A package builds one per test target, so a mutant
    /// several of them could catch starts several processes and loads several bundles -
    /// and a budget that charged for one would meet its deadline on the arithmetic rather
    /// than on anything about the program.
    @Test("charges the fixed cost once per bundle")
    func perBundleIntercept() {
        let one = Self.derived.forTrial(bundles: 1, tests: 200)
        let three = Self.derived.forTrial(bundles: 3, tests: 200)
        #expect(three > one)
        // Two extra bundles at two seconds each, times the slack.
        #expect(three - one == .milliseconds(20_000))
    }

    /// More tests than the suite has is not a thing that can happen, and clamping is
    /// cheaper than trusting the caller.
    @Test("never charges for more tests than the suite has")
    func clampsToTheSuite() {
        #expect(
            Self.derived.forTrial(bundles: 1, tests: 5_000)
                == Self.derived.forTrial(bundles: 1, tests: nil))
    }

    /// An explicit `--timeout` is an answer, not an input. Somebody who set it is telling
    /// the tool what they want, and deriving something else from their suite would be
    /// overruling them quietly.
    @Test("hands back exactly what was asked for, when something was")
    func flatWins() {
        let asked = Budget.flat(.seconds(90))
        #expect(asked.forTrial(bundles: 1, tests: 1) == .seconds(90))
        #expect(asked.forTrial(bundles: 9, tests: nil) == .seconds(90))
    }

    /// A suite whose measurement says a test costs nothing still needs the process cost,
    /// and a suite with no tests at all must not divide by zero.
    @Test("survives a suite it learned nothing from")
    func degenerate() {
        let nothing = Budget.derived(
            fixedMilliseconds: 0,
            perTestMilliseconds: 0,
            everyTest: 0,
            slack: 5,
            floor: .seconds(30)
        )
        #expect(nothing.forTrial(bundles: 1, tests: nil) == .seconds(30))
        #expect(nothing.forTrial(bundles: 0, tests: 0) == .seconds(30))
    }
}

/// Working the deadline out from what the run measured.
@Suite("Deriving a deadline")
struct BudgetDerivationTests {

    /// The whole suite took a hundred seconds over a thousand tests, and one test alone
    /// took two - so two seconds is what a trial costs before it runs anything, and the
    /// remaining ninety-eight milliseconds each is what the tests cost.
    @Test("splits the suite into what a trial costs and what its tests cost")
    func splitsFixedFromPerTest() {
        let budget = Budget.deriving(
            suiteMilliseconds: 100_000,
            tests: 1_000,
            oneTestMilliseconds: 2_000,
            floor: .seconds(30)
        )
        #expect(budget.forTrial(bundles: 1, tests: nil) == .milliseconds(500_000))
        #expect(budget.forTrial(bundles: 1, tests: 100) == .milliseconds(59_000))
    }

    /// Nothing measured a solitary trial, so nothing is assumed about it. Charging a
    /// fixed cost nobody observed would be inventing the one number this cannot see.
    @Test("assumes no fixed cost when none was measured")
    func withoutAMeasuredIntercept() {
        let budget = Budget.deriving(
            suiteMilliseconds: 100_000,
            tests: 1_000,
            oneTestMilliseconds: nil,
            floor: .seconds(30)
        )
        // The whole suite still costs the whole suite; only the split is unknown.
        #expect(budget.forTrial(bundles: 1, tests: nil) == .milliseconds(500_000))
    }

    /// A trial that reported taking longer alone than the whole suite took is a
    /// measurement of a busy machine rather than of a trial. Believing it would leave the
    /// per-test cost negative and every narrow mutant with a deadline in the past.
    @Test("refuses a solitary trial that cost more than the whole suite")
    func refusesNonsense() {
        let budget = Budget.deriving(
            suiteMilliseconds: 10_000,
            tests: 100,
            oneTestMilliseconds: 50_000,
            floor: .seconds(30)
        )
        #expect(budget.forTrial(bundles: 1, tests: 1) >= .seconds(30))
        #expect(budget.forTrial(bundles: 1, tests: nil) >= budget.forTrial(bundles: 1, tests: 1))
    }
}
