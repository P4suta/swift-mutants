// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// How long one mutant gets, given how much of the suite it actually faces.
///
/// This was one number for every mutant: five times the whole contended suite, a floor of
/// thirty seconds, and coverage not consulted at all. Coverage is the tool's largest
/// saving and it was being spent in one direction only - a mutant reached by forty-five of
/// a package's 1333 tests ran forty-five tests and was then given the budget of all 1333.
/// Reported from a real package: 898 seconds for a trial that runs 3.4% of the suite.
/// Fifteen minutes to establish that a mutant finishing in under one had not hung.
///
/// The shape is an intercept and a slope, and the argument for it is structural rather
/// than measured. A trial's cost has a part that does not depend on how many tests run -
/// start a process, load a bundle, bring up the runtime - and a part that does. Scaling by
/// proportion alone gets the small cases catastrophically wrong: `suite / everyTest` will
/// not start a process, let alone load a bundle, so every narrowed mutant would meet its
/// deadline, earn a serial retry, and turn a parallel run into a sequential one. The
/// intercept is not a refinement of the scaling; it is what makes the scaling usable.
///
/// The intercept is charged per bundle rather than per trial. A package builds one test
/// bundle per test target, so a mutant several of them could catch starts several
/// processes and loads several bundles - and a budget charging for one would meet its
/// deadline on this tool's arithmetic rather than on anything about the program.
///
/// The asymmetry sets every direction. A deadline met under load costs one serial retry; a
/// deadline set too tight reports a survivor as a detection, which is the mistake nobody
/// ever finds out about. So every unknown here resolves towards more time.
public enum Budget: Sendable, Hashable {

    /// What somebody asked for, for every mutant alike.
    ///
    /// An explicit `--timeout` is an answer rather than an input. Deriving something else
    /// from their suite would be overruling them quietly.
    case flat(Duration)

    /// Worked out from what the suite costs and how much of it a mutant faces.
    case derived(Terms)

    /// What a suite was measured to cost, split into the parts a deadline needs.
    public struct Terms: Sendable, Hashable {

        /// What a trial costs before it runs any test: process start, bundle load.
        public let fixedMilliseconds: Int

        /// What one test costs once the process is up.
        public let perTestMilliseconds: Int

        /// How many tests the whole suite has, which is what "faces everything" means.
        public let everyTest: Int

        /// How much room to leave for a machine busier than the one measured.
        public let slack: Int

        /// Never less than this, however little a mutant faces.
        public let floor: Duration

        /// Records a measured suite.
        public init(
            fixedMilliseconds: Int,
            perTestMilliseconds: Int,
            everyTest: Int,
            slack: Int,
            floor: Duration
        ) {
            self.fixedMilliseconds = fixedMilliseconds
            self.perTestMilliseconds = perTestMilliseconds
            self.everyTest = everyTest
            self.slack = slack
            self.floor = floor
        }
    }

    /// The same, spelled out, for a caller that has the numbers rather than a suite.
    public static func derived(
        fixedMilliseconds: Int,
        perTestMilliseconds: Int,
        everyTest: Int,
        slack: Int,
        floor: Duration
    ) -> Self {
        .derived(
            Terms(
                fixedMilliseconds: fixedMilliseconds,
                perTestMilliseconds: perTestMilliseconds,
                everyTest: everyTest,
                slack: slack,
                floor: floor
            ))
    }

    /// How long a trial gets: this many bundles, offered this many tests.
    ///
    /// `nil` tests means the whole suite, which is what a mutant with no coverage faces.
    public func forTrial(bundles: Int, tests: Int?) -> Duration {
        switch self {
        case .flat(let asked):
            return asked
        case .derived(let terms):
            let facing = min(max(tests ?? terms.everyTest, 0), terms.everyTest)
            let processes = max(bundles, 1)
            let work =
                terms.fixedMilliseconds * processes + terms.perTestMilliseconds * facing
            return max(terms.floor, .milliseconds(work * max(terms.slack, 1)))
        }
    }

    /// Splits a measured suite into what a trial costs and what its tests cost.
    ///
    /// `oneTestMilliseconds` is a trial that ran almost nothing - the probe phase runs one
    /// test per process and is the same shape as a mutant's trial, on the same machine
    /// under the same contention, so its cheapest observation is the closest thing to a
    /// measurement of the intercept that exists. Absent when nothing measured one, and
    /// then nothing is assumed about it: charging a fixed cost nobody observed would be
    /// inventing the one number this cannot see.
    ///
    /// A solitary trial reported as costing more than the whole suite is a measurement of
    /// a busy machine rather than of a trial. Believing it would make the per-test cost
    /// negative and hand every narrow mutant a deadline in the past, so it is refused and
    /// the split falls back to knowing only the total.
    public static func deriving(
        suiteMilliseconds suite: Int,
        tests: Int,
        oneTestMilliseconds: Int?,
        slack: Int = 5,
        floor: Duration = .seconds(30)
    ) -> Self {
        let total = max(suite, 0)
        let count = max(tests, 0)
        let fixed = (oneTestMilliseconds ?? 0) <= total ? max(oneTestMilliseconds ?? 0, 0) : 0
        let perTest = count > 0 ? max(total - fixed, 0) / count : 0
        return .derived(
            Terms(
                fixedMilliseconds: fixed,
                perTestMilliseconds: perTest,
                everyTest: count,
                slack: slack,
                floor: floor
            ))
    }
}
