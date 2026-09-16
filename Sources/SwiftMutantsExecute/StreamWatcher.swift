// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore

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

    /// The tests that stepped aside rather than running.
    ///
    /// Kept apart from ``startedTests`` because a skipped test did not run: counting it
    /// among the ones that did would make every test look cheaper than it is, and a
    /// deadline derived from the count would be derived from a number nobody measured.
    public private(set) var skipped: [String] = []

    /// What this watcher is waiting to learn.
    ///
    /// Watching one mutant, the first failure is the end of the story. Watching a batch it
    /// is not - the other mutants in the process have not been asked yet - and watching a
    /// baseline there is no story to end, because the whole suite is the answer.
    public enum Settlement: Sendable, Hashable {

        /// One mutant. The first failure decides it and nothing else can.
        case oneMutant

        /// No mutant at all: the run is the answer and every test of it counts.
        case wholeSuite

        /// Several mutants, each owning some of the tests, none owning the same one.
        ///
        /// Decided when every owner is - by one of its own tests failing, or by the last
        /// of them passing. A batch does not need every test; it needs every mutant, and
        /// running past that is the launch saving spent again on tests.
        case eachOwner([String: UInt32])
    }

    /// What it is waiting to learn.
    private let settlement: Settlement

    /// How many of each owner's tests have not ended yet.
    private var outstanding: [UInt32: Int] = [:]

    /// The owners that have been decided, either way.
    private var settled: Set<UInt32> = []

    /// How many owners there are to decide.
    private let owners: Int

    /// Whether anything is still worth waiting for.
    public var isDecided: Bool {
        switch settlement {
        case .oneMutant: !killers.isEmpty
        case .wholeSuite: false
        case .eachOwner: settled.count == owners
        }
    }

    /// Starts watching one mutant, which is the ordinary case.
    public init() {
        self.init(settling: .oneMutant)
    }

    /// Starts watching for `settling`.
    public init(settling: Settlement) {
        self.settlement = settling
        switch settling {
        case .oneMutant, .wholeSuite:
            self.owners = 0
        case .eachOwner(let map):
            var counts: [UInt32: Int] = [:]
            for owner in map.values { counts[owner, default: 0] += 1 }
            self.outstanding = counts
            self.owners = counts.count
        }
    }

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
            Self.function(event).map { startedTests.append($0) }
        case .issueRecorded:
            guard event.isFailure else { break }
            killers.append(event.testID ?? "<unnamed test>")
            if firstFailure == nil { firstFailure = event.message }
            settle(event.testID)
        case .testEnded:
            ended(event.testID)
        case .testSkipped:
            Self.function(event).map { skipped.append($0) }
        case .other: break
        }
        return !isDecided
    }

    /// The identifier of a test function, or nothing for an event about a suite.
    ///
    /// Only a test function has an identifier worth keeping. A suite emits its own
    /// `testStarted` and, when it steps aside, its own `testSkipped` as well as one per
    /// test underneath it - so counting suites would run a suite's children when filtering
    /// by the started list, and would report every skipped suite twice.
    ///
    /// The parenthesis is what tells them apart: swift-testing spells a test function's id
    /// with its argument list and a suite's without.
    private static func function(_ event: TestEvent) -> String? {
        guard let id = event.testID, id.contains("(") else { return nil }
        return id
    }

    /// Marks the mutant that owns `test` as decided, whichever way it went.
    private mutating func settle(_ test: String?) {
        guard case .eachOwner(let map) = settlement, let test, let owner = map[test] else {
            return
        }
        settled.insert(owner)
        outstanding[owner] = 0
    }

    /// Accounts for one of an owner's tests finishing.
    ///
    /// An owner whose last test has ended without failing has survived, which is decided
    /// as firmly as being caught. A test nobody owns settles nobody: it is the sign that
    /// the batch was built wrong, which the caller checks for separately, and crediting it
    /// to whoever is nearby is exactly the guess that must not be made.
    private mutating func ended(_ test: String?) {
        guard case .eachOwner(let map) = settlement, let test, let owner = map[test],
            let left = outstanding[owner], left > 0
        else {
            return
        }
        outstanding[owner] = left - 1
        if left == 1 { settled.insert(owner) }
    }

    /// What it all amounted to, once the process has gone.
    ///
    /// The rules, and why each one is the way round it is:
    ///
    /// - A failure seen is a kill, whatever the process did afterwards. The mutant was
    ///   noticed; how the process ended is then beside the point.
    /// - A process this watcher stopped because it had learned everything it was waiting
    ///   for has an answer, and it is the answer. Only a stop it did not ask for - a
    ///   deadline, an interrupt - leaves it knowing nothing.
    /// - A process the kernel stopped for using more processor than it was allowed did not
    ///   terminate. That is the same finding a deadline makes and better evidence for it,
    ///   so it is the same outcome and is never retried.
    /// - A process that started running tests and then died without finishing was killed
    ///   *by the mutant*: `try!` and `x!` mutants trap, and a trap takes the process with
    ///   it. Counting that as tooling trouble would lose the most reliably-caught mutants
    ///   there are.
    /// - A process that never started a test proves nothing, whatever it exited with. That
    ///   is `errored`, and it keeps a broken harness out of the score rather than letting
    ///   it read as a suite that passed.
    /// - Only a clean finish with no failures is `survived`, which is the answer that
    ///   costs somebody work, and so the one held to the strictest evidence.
    public func verdict(
        after termination: Termination, taking milliseconds: Int = 0, working cpu: Int? = nil
    ) -> Verdict {
        Verdict(
            outcome: outcome(after: termination),
            killedBy: killers,
            firstFailure: firstFailure,
            startedTests: startedTests,
            durationMilliseconds: milliseconds,
            skippedTests: skipped,
            cpuMilliseconds: cpu,
            termination: termination
        )
    }

    private func outcome(after termination: Termination) -> Outcome {
        if !killers.isEmpty { return .killed }
        switch termination {
        case .stopped:
            // Two kinds of stop, meaning opposite things. One this watcher asked for,
            // having learned everything it was waiting for - which is how most of a run's
            // time is saved, and the answer after it is the answer. One it did not ask for -
            // a deadline, an interrupt - after which it knows nothing, whatever ran first.
            guard isDecided, !startedTests.isEmpty else { return .errored }
            return .survived
        case .timedOut, .overranWork:
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
