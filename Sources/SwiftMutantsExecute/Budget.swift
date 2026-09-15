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
///
/// ## What this used to not do, and why it no longer has to
///
/// Both terms were measured once, at the start, in wall time - and a machine that got busier
/// afterwards made every one of them an underestimate for the rest of the run. Reported from
/// a real package: a baseline of 898 seconds became 1767 because somebody started a full
/// build in another window, and every deadline after that point came from the wrong number.
/// Mutants met deadlines they should not have, were retried, met them again, and were
/// recorded as detections.
///
/// The obvious answer was to notice the drift: every trial reports what it cost and this
/// predicts one, so a run whose last several trials all took several times what was
/// predicted knows the model is wrong. It was written down here and deliberately not built,
/// on the grounds that the state it needs is shared across concurrent workers.
///
/// It was never built because the right answer was to stop measuring the wrong thing. A
/// process doing the same work consumes the same *processor* seconds however busy the
/// machine is, so an allowance derived from ``Terms/cpu`` does not drift at all - and the
/// kernel enforces it, so nothing has to watch for anything.
///
/// What is left is the clock, and it does still drift. It no longer costs a false detection,
/// because it is no longer the limit: ``forTrial(bundles:tests:)`` widens it to twenty times
/// the allowance, which is past any oversubscription a real machine has. A trial that has
/// not spent its allowance is working slowly; a trial that goes twenty times past it is not
/// working at all, which is a deadlock, and a deadlock is the only thing the clock is here
/// to catch.
///
/// A run that could not measure its own processor time has no allowance, and the clock is
/// the limit again - which is where this tool was, and where the drift above would apply.
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

        /// The same two terms again, in processor time, when it could be measured.
        ///
        /// The unit a limit belongs in. A deadline in wall time is a statement about the
        /// machine as much as about the suite: a baseline of 898 seconds became 1767
        /// because a build started in another window, and every deadline derived from it
        /// afterwards was too tight - so mutants met deadlines, were retried, met them
        /// again, and were recorded as detections. A process doing the same work consumes
        /// the same processor seconds however busy the machine is, so an allowance in this
        /// unit is a statement about the program and there is no drift to notice.
        ///
        /// Absent when nothing was measured, which is not the same as zero: a run that
        /// could not read its own processor time has no allowance to give, and the wall
        /// clock is what is left.
        public let cpu: Work?

        /// Records a measured suite.
        public init(
            fixedMilliseconds: Int,
            perTestMilliseconds: Int,
            everyTest: Int,
            slack: Int,
            floor: Duration,
            cpu: Work? = nil
        ) {
            self.fixedMilliseconds = fixedMilliseconds
            self.perTestMilliseconds = perTestMilliseconds
            self.everyTest = everyTest
            self.slack = slack
            self.floor = floor
            self.cpu = cpu
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
            let clock = max(terms.floor, .milliseconds(work * max(terms.slack, 1)))
            // And well past the allowance, when there is one. The deadline is no longer
            // deciding anything a healthy trial could trip over - the allowance is - so it
            // only has to be finite, and a deadline still tuned to be the limit would go on
            // producing exactly the false detections the allowance removes.
            //
            // A trial that has not spent its allowance is a trial that is *working*, slowly,
            // on a machine somebody else is using. Twenty times is past any oversubscription
            // a real machine has: with one worker per core a trial gets about a core, so
            // wall time and processor time are close, and another tenant taking most of the
            // machine is a factor of a few.
            guard let allowance = cpuForTrial(bundles: bundles, tests: tests) else {
                return clock
            }
            return max(clock, allowance * Self.backstop)
        }
    }

    /// How far past its allowance a trial may run before the clock stops it.
    ///
    /// The number is a statement about machines rather than about suites: how badly
    /// oversubscribed one can plausibly be while a trial is still making progress. Past
    /// that, a trial which has not spent its allowance is not working at all, which is a
    /// deadlock - and a deadlock is the only thing this is here to catch.
    public static let backstop = 20

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
        cpuSuiteMilliseconds: Int? = nil,
        cpuOneTestMilliseconds: Int? = nil,
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
                floor: floor,
                cpu: Self.work(
                    suite: cpuSuiteMilliseconds, oneTest: cpuOneTestMilliseconds, tests: count)
            ))
    }

    /// The same split, applied to what the suite cost in processor time.
    private static func work(suite: Int?, oneTest: Int?, tests: Int) -> Work? {
        guard let suite else { return nil }
        let total = max(suite, 0)
        let fixed = (oneTest ?? 0) <= total ? max(oneTest ?? 0, 0) : 0
        return Work(
            fixedMilliseconds: fixed,
            perTestMilliseconds: tests > 0 ? max(total - fixed, 0) / tests : 0
        )
    }

    /// How much processor a trial may use: this many bundles, offered this many tests.
    ///
    /// `nil` when nothing was measured, and when a deadline was asked for by name. An
    /// explicit `--timeout` is an answer about the clock, and deriving an allowance in a
    /// different unit that the person did not ask for would be overruling them in a way
    /// they could not see.
    ///
    /// The floor is smaller than the deadline's, and deliberately: an allowance is spent
    /// only by working, so a trial that waits for a fixture or a port spends none of it.
    /// Five seconds of processor is a great deal of work for a handful of tests.
    public func cpuForTrial(bundles: Int, tests: Int?) -> Duration? {
        guard case .derived(let terms) = self, let work = terms.cpu else { return nil }
        let facing = min(max(tests ?? terms.everyTest, 0), terms.everyTest)
        let processes = max(bundles, 1)
        let spent = work.fixedMilliseconds * processes + work.perTestMilliseconds * facing
        return max(Self.cpuFloor, .milliseconds(spent * max(terms.slack, 1)))
    }

    /// The least processor any trial is allowed.
    ///
    /// A suite measured quick for reasons that say nothing about one mutant - a warm cache,
    /// a machine that happened to be idle - must not produce an allowance a healthy trial
    /// cannot meet.
    public static let cpuFloor = Duration.seconds(5)
}

/// What a suite costs in processor time, split the way a deadline's terms are.
///
/// Its own type rather than a second pair of fields, because it is a different measurement
/// of the same suite and the two must not be mistaken for each other anywhere.
public struct Work: Sendable, Hashable {

    /// What a trial costs before it runs any test.
    public let fixedMilliseconds: Int

    /// What one test costs once the process is up.
    public let perTestMilliseconds: Int

    /// Records a measured suite's work.
    public init(fixedMilliseconds: Int, perTestMilliseconds: Int) {
        self.fixedMilliseconds = fixedMilliseconds
        self.perTestMilliseconds = perTestMilliseconds
    }
}
