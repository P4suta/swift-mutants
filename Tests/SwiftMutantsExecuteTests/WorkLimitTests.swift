// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsExecute

/// A mutant stopped for the work it did, rather than for how long it took.
///
/// The two are the same finding - the mutant did not terminate - and one of them is much
/// better evidence. A deadline says nothing was learned in the time allowed, which on a busy
/// machine may be a fact about the machine; an allowance says the process did more work than
/// it was given, which is the same on any machine.
///
/// So the outcome is the same and everything downstream of it changes. It is not retried,
/// because there is nothing a quieter machine would settle. And it does not turn a batch
/// into eight survivors, because a process the kernel stopped did not reach the end of what
/// it was asked to do.
@Suite("Stopped for its work")
struct WorkLimitTests {

    static func verdict(_ termination: Termination, started: [String] = ["P.S/f()"]) -> Verdict {
        var watcher = StreamWatcher(settling: .oneMutant)
        for test in started {
            _ = watcher.observe(
                TestEvent(
                    kind: .testStarted,
                    testID: test,
                    isFailure: false,
                    isKnown: false,
                    message: nil))
        }
        return watcher.verdict(after: termination)
    }

    /// The same outcome as a deadline, because it is the same finding about the program.
    @Test("is the finding a deadline makes")
    func sameOutcome() {
        #expect(Self.verdict(.overranWork).outcome == .timedOut)
    }

    /// A process that started nothing establishes nothing, whatever stopped it. That is a
    /// harness that did not work, and it must stay out of the score.
    @Test("says nothing about a mutant whose tests never started")
    func nothingStarted() {
        #expect(Self.verdict(.overranWork, started: []).outcome == .errored)
    }

    /// The reason it is better evidence, in the one place the difference shows: a batch
    /// whose process was stopped has nothing to share out, because the mutants whose tests
    /// had not run were never measured.
    @Test("is not a process that reached the end of what it was asked")
    func notSettled() {
        #expect(!Termination.overranWork.settled)
    }

    /// Kept apart from a deadline so that the retry can tell them apart. A mutant stopped
    /// on a quiet machine for doing too much work would be stopped again for the same
    /// reason, and the second look would cost the allowance a second time.
    @Test("is not the same termination as a deadline")
    func notADeadline() {
        #expect(Termination.overranWork != Termination.timedOut)
    }
}
