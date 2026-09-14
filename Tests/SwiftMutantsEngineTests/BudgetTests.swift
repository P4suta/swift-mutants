// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsExecute
import Testing

@testable import SwiftMutantsEngine

/// How long one mutant is allowed to take.
///
/// A number picked out of the air is either so tight that a loaded machine reports a
/// working suite as a hang, or so loose that a mutant which really does hang costs the
/// whole budget. The only thing that tells the two apart is how long this suite takes when
/// nothing is wrong with it - which a run already measures, because it runs the
/// instrumented baseline before it runs anything else.
///
/// The failure this prevents was measured on this repository: 592 mutants, 82 deadlines,
/// 0 survivors reported, and a score of 100% that was not true of anything. A killed
/// mutant stops at the first test that notices it, so the mutants that meet a deadline are
/// overwhelmingly the survivors - and a deadline counts as a detection.
@Suite("Deadlines")
struct BudgetTests {

    static func baseline(taking milliseconds: Int) -> Verdict {
        Verdict(
            outcome: .survived,
            killedBy: [],
            firstFailure: nil,
            startedTests: (1...10).map { "P.S/t\($0)()" },
            durationMilliseconds: milliseconds,
            termination: .exited(0)
        )
    }

    @Test("gives a mutant several times what the suite takes")
    func multiplesOfTheBaseline() {
        #expect(Run.budget(from: Self.baseline(taking: 20_000), jobs: 1) == .seconds(100))
    }

    /// Not multiplied by the workers. A deadline is no longer the last word - a mutant
    /// that misses one is run again, alone - and a budget that allowed for every worker
    /// slowing every other one made a genuine hang cost sixteen minutes of a run.
    @Test("does not stretch for the number of workers")
    func doesNotScaleWithJobs() {
        let alone = Run.budget(from: Self.baseline(taking: 20_000), jobs: 1)
        let crowded = Run.budget(from: Self.baseline(taking: 20_000), jobs: 8)
        #expect(crowded == alone)
    }

    /// A suite that takes no time at all still needs a deadline a loaded machine can meet.
    @Test(
        "never gives less than half a minute",
        arguments: [0, 1, 100, 5_000])
    func floor(milliseconds: Int) {
        #expect(Run.budget(from: Self.baseline(taking: milliseconds), jobs: 1) >= .seconds(30))
    }

    /// Long suites get proportionally long deadlines rather than the floor.
    @Test("grows with the suite rather than sitting at the floor")
    func growsWithTheSuite() {
        let short = Run.budget(from: Self.baseline(taking: 10_000), jobs: 4)
        let long = Run.budget(from: Self.baseline(taking: 60_000), jobs: 4)
        #expect(long > short)
        #expect(long == .seconds(300))
    }
}
