// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsExecute

/// Turning what a test process did into an answer about a mutant.
///
/// Every rule here is the way round it is because the two mistakes are not symmetric.
/// Calling a live mutant dead hides a hole in somebody's tests; calling a dead one alive
/// costs them an afternoon finding out it was not. The second is expensive and the first is
/// dangerous, so `survived` is the answer held to the strictest evidence.
@Suite("Verdicts")
struct VerdictTests {

    static func watcher(_ events: [TestEvent]) -> StreamWatcher {
        var watcher = StreamWatcher()
        for event in events { watcher.observe(event) }
        return watcher
    }

    static func event(
        _ kind: TestEvent.Kind,
        testID: String? = nil,
        isFailure: Bool = false,
        message: String? = nil
    ) -> TestEvent {
        TestEvent(
            kind: kind, testID: testID, isFailure: isFailure, isKnown: false, message: message)
    }

    static let ran = [event(.runStarted), event(.testStarted, testID: "P.S/f()")]

    @Test("calls a clean finish with no failures survived")
    func survived() {
        let watcher = Self.watcher(Self.ran + [Self.event(.testEnded), Self.event(.runEnded)])
        #expect(watcher.verdict(after: .exited(0)).outcome == .survived)
    }

    @Test("calls a failure a kill, and says which test")
    func killed() {
        let watcher = Self.watcher(
            Self.ran + [
                Self.event(.issueRecorded, testID: "P.S/f()", isFailure: true, message: "3 == 4")
            ]
        )
        let verdict = watcher.verdict(after: .stopped)
        #expect(verdict.outcome == .killed)
        #expect(verdict.killedBy == ["P.S/f()"])
        #expect(verdict.firstFailure == "3 == 4")
    }

    /// `x!` and `try!` mutants trap, and a trap takes the process with it. Counting that
    /// as tooling trouble would lose the most reliably-caught mutants there are.
    @Test("calls a process that died mid-suite a kill")
    func crashIsAKill() {
        let watcher = Self.watcher(Self.ran)
        #expect(watcher.verdict(after: .exited(139)).outcome == .killed)
    }

    /// A harness that never got as far as a test proves nothing, and must not read as a
    /// suite that passed.
    @Test(
        "calls a run that started no tests errored",
        arguments: [Termination.exited(0), .exited(1), .timedOut, .couldNotStart("no such file")]
    )
    func nothingRanIsErrored(termination: Termination) {
        #expect(StreamWatcher().verdict(after: termination).outcome == .errored)
    }

    /// A process that exits cleanly without saying the run ended did not finish the suite.
    /// Reading that as `survived` would credit a mutant with surviving tests that never ran.
    @Test("does not call an unfinished run survived")
    func unfinishedIsNotSurvived() {
        let watcher = Self.watcher(Self.ran)
        #expect(watcher.verdict(after: .exited(0)).outcome == .errored)
    }

    @Test("calls a run that ran out of time timed out")
    func timedOut() {
        #expect(Self.watcher(Self.ran).verdict(after: .timedOut).outcome == .timedOut)
    }

    /// A failure seen is a kill whatever happened next: the mutant was noticed, and how
    /// the process ended afterwards says nothing further.
    @Test(
        "keeps a kill whatever the process did next",
        arguments: [Termination.exited(0), .exited(1), .stopped, .timedOut]
    )
    func killSticks(termination: Termination) {
        let watcher = Self.watcher(
            Self.ran + [Self.event(.issueRecorded, testID: "P.S/f()", isFailure: true)])
        #expect(watcher.verdict(after: termination).outcome == .killed)
    }

    /// The point of watching rather than waiting.
    @Test("says to stop the moment a test fails, and not before")
    func stopsOnTheFirstFailure() {
        // Bound before asserting: `observe` is mutating, and the expectation macro
        // captures what it is given immutably.
        var watcher = StreamWatcher()
        let afterRunStarted = watcher.observe(Self.event(.runStarted))
        let afterTestStarted = watcher.observe(Self.event(.testStarted, testID: "P.S/a()"))
        let afterTestEnded = watcher.observe(Self.event(.testEnded, testID: "P.S/a()"))
        let afterFailure = watcher.observe(
            Self.event(.issueRecorded, testID: "P.S/b()", isFailure: true))
        #expect(afterRunStarted)
        #expect(afterTestStarted)
        #expect(afterTestEnded)
        #expect(!afterFailure)
    }

    /// A known issue is an error by severity and not a failure. Stopping on one would
    /// report a mutant as killed by a test documented as currently failing.
    @Test("does not stop for an issue that is not a failure")
    func doesNotStopForAKnownIssue() {
        var watcher = StreamWatcher()
        watcher.observe(Self.event(.runStarted))
        watcher.observe(Self.event(.testStarted, testID: "P.S/w()"))
        let afterKnownIssue = watcher.observe(
            Self.event(.issueRecorded, testID: "P.S/w()", isFailure: false))
        #expect(afterKnownIssue)
        #expect(watcher.killers.isEmpty)
    }

    /// A suite allowed to run on can report several. The first is the one a person should
    /// look at, and the order has to be the order they arrived.
    @Test("keeps every failing test, in the order they failed")
    func keepsEveryKiller() {
        let watcher = Self.watcher(
            Self.ran + [
                Self.event(.issueRecorded, testID: "P.S/b()", isFailure: true),
                Self.event(.issueRecorded, testID: "P.S/a()", isFailure: true),
            ]
        )
        #expect(watcher.verdict(after: .stopped).killedBy == ["P.S/b()", "P.S/a()"])
    }

    /// An issue with no test named is still a failure. Dropping it would turn a kill into
    /// a survival because of a missing field.
    @Test("counts a failure that names no test")
    func unnamedFailure() {
        let watcher = Self.watcher(Self.ran + [Self.event(.issueRecorded, isFailure: true)])
        #expect(watcher.verdict(after: .stopped).outcome == .killed)
        #expect(watcher.verdict(after: .stopped).killedBy == ["<unnamed test>"])
    }
}
