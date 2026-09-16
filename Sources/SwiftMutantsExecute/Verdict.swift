// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// How a test process ended.
public enum Termination: Sendable, Hashable {

    /// It finished on its own with this status.
    case exited(Int)

    /// This tool stopped it, because the answer was already known.
    case stopped

    /// It ran out of time.
    case timedOut

    /// It used more processor than it was allowed.
    ///
    /// Apart from ``timedOut`` because it is better evidence, not merely different. A
    /// deadline says nothing was learned in the time allowed, which on a busy machine may
    /// be a fact about the machine; this says the process did more *work* than the
    /// allowance, which is the same on any machine and needs no second opinion. So a mutant
    /// stopped this way is not retried: there is nothing a quieter machine would change.
    case overranWork

    /// It never became a process.
    case couldNotStart(String)

    /// Whether the process reached the end of what it was asked to do.
    ///
    /// The question a batch turns on. Several mutants run in one process and the answer is
    /// shared out by which test failed, so a process that stopped part way has nothing to
    /// say about the mutants whose tests had not run yet - and "no test failed for you" is
    /// exactly what surviving looks like.
    ///
    /// A trap is the case that matters. Bounds arithmetic is where mutation testing earns
    /// its keep, and a mutation to bounds arithmetic traps: the process dies on a signal
    /// with no failure event, because there is no assertion, only a trap. Measured on a
    /// package of two hand-written binary codecs, where a batch that died that way reported
    /// every mutant in it as surviving a program it had destroyed.
    public var settled: Bool {
        switch self {
        case .stopped: true
        case .exited(let status): status == 0
        case .timedOut, .overranWork, .couldNotStart: false
        }
    }
}

/// What one mutant amounted to, and what led there.
public struct Verdict: Sendable, Hashable {

    /// The answer.
    public let outcome: Outcome

    /// The tests that failed while the mutant was awake, in the order they failed.
    ///
    /// Plural because a suite that is not stopped early can report several, and the first
    /// is the one that matters: it is the test a person should look at, and the one
    /// `explain` prints a command for.
    public let killedBy: [String]

    /// What the first failing test said.
    public let firstFailure: String?

    /// How many tests were seen to start.
    ///
    /// A run that started none is a run that proves nothing, whatever it exited with.
    public var testsStarted: Int { startedTests.count }

    /// Which tests were seen to start, in the order they did.
    ///
    /// The baseline's list is the suite, and the suite is what a probe asks one test at a
    /// time. Taken from the stream rather than from a separate listing command, because
    /// the tests that ran are the tests there are - a listing could disagree with reality
    /// and the disagreement would be silent.
    public let startedTests: [String]

    /// How long the test process ran, in milliseconds.
    ///
    /// What a deadline is derived from. A budget picked out of the air is either so tight
    /// that a loaded machine reports a suite as a hang, or so loose that a mutant which
    /// really does hang costs the whole budget - and the only number that tells the two
    /// apart is how long this suite takes when nothing is wrong with it.
    public let durationMilliseconds: Int

    /// The tests that did not run, because they declared themselves disabled.
    ///
    /// Said rather than dropped, and it matters most for the baseline. A test whose
    /// fixtures live outside the package cannot run in the copy every run happens in, and
    /// the mutants only it covers then come back as survivors nobody can write a test for -
    /// the test already exists, and it cannot run here. Reported from a package with five
    /// such suites, pinning a Base32 alphabet and two key-derivation strings against the
    /// documents that specify them.
    ///
    /// Not a failure. A suite that steps aside when its fixtures are absent is doing the
    /// right thing, and refusing to measure a package over it would be worse than saying so.
    public let skippedTests: [String]

    /// How much processor the trial used, when it was asked to account for it.
    ///
    /// The number a budget should be derived from, and the reason is the one above read
    /// again: how long a suite takes is a fact about the machine as much as about the
    /// suite, and how much work it does is a fact about the suite alone. A baseline taken
    /// on a quiet machine and applied on a busy one is too tight in wall time and exactly
    /// right in this.
    ///
    /// Absent when nothing was measured, which is not zero: a trial that could not account
    /// for itself leaves the wall clock as the only limit, which is where this tool was.
    public let cpuMilliseconds: Int?

    /// How the process ended.
    ///
    /// Kept beside the outcome rather than folded into it, because two mutants that are
    /// both `killed` are not the same news: one was caught by the second test and the
    /// suite was stopped there, the other ran to the end and failed at the last. `explain`
    /// prints this, and a reader deciding whether their suite is slow needs it.
    public let termination: Termination

    /// Records what a run of the tests amounted to.
    public init(
        outcome: Outcome,
        killedBy: [String],
        firstFailure: String?,
        startedTests: [String],
        durationMilliseconds: Int,
        skippedTests: [String] = [],
        cpuMilliseconds: Int? = nil,
        termination: Termination
    ) {
        self.outcome = outcome
        self.killedBy = killedBy
        self.firstFailure = firstFailure
        self.startedTests = startedTests
        self.durationMilliseconds = durationMilliseconds
        self.skippedTests = skippedTests
        self.cpuMilliseconds = cpuMilliseconds
        self.termination = termination
    }
}

extension Verdict {

    /// One answer from several bundles.
    ///
    /// A trial used to be one process, because a package used to build one test bundle. It
    /// now builds one per test target, so a mutant several bundles could catch is several
    /// processes - and the answer has to read as one, because a mutant has one verdict and
    /// a score has one denominator.
    ///
    /// The asymmetry decides every rule. `survived` is a claim about every test that could
    /// have caught it, so it needs all of them to have looked; `killed` is a claim about
    /// one, so the first is enough. A deadline sits between: it establishes nothing about
    /// the bundles it did not reach, so it beats survival - reading it as survival would
    /// report a mutant nothing caught when what happened is that nothing finished looking -
    /// and loses to a kill, which answered the question the deadline was still asking.
    ///
    /// Nothing at all is not an answer about a program. It means the caller worked out that
    /// nothing could run and started nothing, and calling that `survived` would put a
    /// mutant nobody measured into a score.
    public static func across(_ verdicts: [Verdict]) -> Verdict {
        guard let first = verdicts.first else {
            return Verdict(
                outcome: .errored,
                killedBy: [],
                firstFailure: "no test bundle was run for this mutant",
                startedTests: [],
                durationMilliseconds: 0,
                termination: .couldNotStart("no bundle to run")
            )
        }
        guard verdicts.count > 1 else { return first }

        let deciding =
            verdicts.first { $0.outcome == .killed }
            ?? verdicts.first { $0.outcome != .survived }
            ?? first
        return Verdict(
            outcome: deciding.outcome,
            killedBy: verdicts.flatMap(\.killedBy),
            firstFailure: verdicts.compactMap(\.firstFailure).first,
            startedTests: verdicts.flatMap(\.startedTests),
            durationMilliseconds: verdicts.reduce(0) { $0 + $1.durationMilliseconds },
            // All of them, for the same reason the answer exists at all: a package with
            // two test targets where one steps aside would otherwise be silent about it,
            // which is the case this was added to stop being silent about.
            skippedTests: verdicts.flatMap(\.skippedTests),
            // Added up, because a mutant facing two bundles did the work of both. Nothing
            // at all when none of them could account for itself.
            cpuMilliseconds: verdicts.compactMap(\.cpuMilliseconds).reduce(into: nil) {
                $0 = ($0 ?? 0) + $1
            },
            termination: deciding.termination
        )
    }
}
