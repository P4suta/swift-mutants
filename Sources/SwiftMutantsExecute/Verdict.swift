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

    /// It never became a process.
    case couldNotStart(String)
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
        termination: Termination
    ) {
        self.outcome = outcome
        self.killedBy = killedBy
        self.firstFailure = firstFailure
        self.startedTests = startedTests
        self.durationMilliseconds = durationMilliseconds
        self.termination = termination
    }
}

/// Watches an event stream and says when the answer is known.
///
/// A separate type from the reading of lines, because this is the part with a decision in
/// it. Given the events, in order, it says whether there is any point in the test process
/// continuing to exist - and the moment there is not, the caller stops it. That is what
/// turns "how long does the suite take" into "how long until something notices", which on
/// a suite of any size is a different question.
public struct StreamWatcher: Sendable {

    /// The tests that failed, in the order their failures arrived.
    public private(set) var killers: [String] = []

    /// What the first failure said.
    public private(set) var firstFailure: String?

    /// Whether the bundle said it had started running.
    public private(set) var started = false

    /// Whether the bundle said it had finished.
    public private(set) var finished = false

    /// Which tests began, in order.
    public private(set) var startedTests: [String] = []

    /// Whether anything is still worth waiting for.
    public var isDecided: Bool { !killers.isEmpty }

    /// Starts watching.
    public init() {}

    /// Takes one event into account.
    ///
    /// Returns whether the caller should keep the process alive. It says stop on the first
    /// failure and never on anything else: a mutant is killed as soon as one test notices
    /// it, and every further second the suite spends is spent establishing something
    /// already established.
    @discardableResult
    public mutating func observe(_ event: TestEvent) -> Bool {
        switch event.kind {
        case .runStarted: started = true
        case .runEnded: finished = true
        case .testStarted:
            // Only a test function has an identifier worth filtering on; a suite's
            // `testStarted` names the suite, and filtering by it would run its children.
            if let id = event.testID, id.contains("(") { startedTests.append(id) }
        case .issueRecorded:
            guard event.isFailure else { break }
            killers.append(event.testID ?? "<unnamed test>")
            if firstFailure == nil { firstFailure = event.message }
        case .testEnded, .other: break
        }
        return !isDecided
    }

    /// What it all amounted to, once the process has gone.
    ///
    /// The rules, and why each one is the way round it is:
    ///
    /// - A failure seen is a kill, whatever the process did afterwards. The mutant was
    ///   noticed; how the process ended is then beside the point.
    /// - A process that started running tests and then died without finishing was killed
    ///   *by the mutant*: `try!` and `x!` mutants trap, and a trap takes the process with
    ///   it. Counting that as tooling trouble would lose the most reliably-caught mutants
    ///   there are.
    /// - A process that never started a test proves nothing, whatever it exited with. That
    ///   is `errored`, and it keeps a broken harness out of the score rather than letting
    ///   it read as a suite that passed.
    /// - Only a clean finish with no failures is `survived`, which is the answer that
    ///   costs somebody work, and so the one held to the strictest evidence.
    public func verdict(after termination: Termination, taking milliseconds: Int = 0) -> Verdict {
        Verdict(
            outcome: outcome(after: termination),
            killedBy: killers,
            firstFailure: firstFailure,
            startedTests: startedTests,
            durationMilliseconds: milliseconds,
            termination: termination
        )
    }

    private func outcome(after termination: Termination) -> Outcome {
        if !killers.isEmpty { return .killed }
        switch termination {
        case .stopped:
            // Nothing else stops a process, so arriving here without a failure means the
            // caller stopped it for a reason this type does not know about.
            return .errored
        case .timedOut:
            return startedTests.isEmpty ? .errored : .timedOut
        case .couldNotStart:
            return .errored
        case .exited(let status):
            guard !startedTests.isEmpty else { return .errored }
            if status == 0 { return finished ? .survived : .errored }
            return .killed
        }
    }
}
