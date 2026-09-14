// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsExecute

/// Knowing when a process has nothing left to tell you.
///
/// Watching one mutant, the first failure is the end of the story. Watching a batch it is
/// not: the other mutants in the process have not been asked yet, so the run used to go on
/// to the last test of the last member - which gave back the launches a batch was there to
/// save and spent them on tests instead. A batch of eight mutants at forty tests each ran
/// three hundred and twenty tests to learn eight things that were often known after eight.
///
/// A batch does not need every test. It needs every *mutant* decided, and a mutant is
/// decided the moment one of its own tests fails or the last of them passes. Tracking that
/// per owner keeps the saving on launches and takes back the saving on tests.
@Suite("Knowing when to stop")
struct SettlementTests {

    static func event(
        _ kind: TestEvent.Kind, testID: String? = nil, isFailure: Bool = false
    ) -> TestEvent {
        TestEvent(kind: kind, testID: testID, isFailure: isFailure, isKnown: false, message: nil)
    }

    /// Two mutants, two tests each.
    static let owners = [
        "P.S/a1()": UInt32(1), "P.S/a2()": UInt32(1),
        "P.S/b1()": UInt32(2), "P.S/b2()": UInt32(2),
    ]

    /// Runs the events through a watcher and says after which one it asked to stop.
    static func stopsAfter(_ events: [TestEvent], settling: StreamWatcher.Settlement) -> Int? {
        var watcher = StreamWatcher(settling: settling)
        for (position, event) in events.enumerated() where !watcher.observe(event) {
            return position
        }
        return nil
    }

    static func failing(_ test: String) -> [TestEvent] {
        [
            event(.testStarted, testID: test),
            event(.issueRecorded, testID: test, isFailure: true),
            event(.testEnded, testID: test),
        ]
    }

    static func passing(_ test: String) -> [TestEvent] {
        [event(.testStarted, testID: test), event(.testEnded, testID: test)]
    }

    /// Both killed by their first test. It stops on the second failure itself rather than
    /// on the event that ends that test: a mutant is caught the moment something notices
    /// it, and the rest of the test it was noticed in is already beside the point.
    @Test("stops once every mutant has been caught")
    func stopsWhenAllAreCaught() {
        let events =
            [Self.event(.runStarted)] + Self.failing("P.S/a1()") + Self.failing("P.S/b1()")
        #expect(Self.stopsAfter(events, settling: .eachOwner(Self.owners)) == 5)
        #expect(events[5].kind == .issueRecorded)
        // Two mutants at two tests each: six of the eleven events a full run would take.
        #expect(events.count == 7)
    }

    /// The half-answer is not an answer. One mutant caught says nothing about the other,
    /// and stopping there would report a mutant as surviving tests it never ran.
    @Test("keeps going while any mutant is still unasked")
    func waitsForTheRest() {
        let events = [Self.event(.runStarted)] + Self.failing("P.S/a1()")
        #expect(Self.stopsAfter(events, settling: .eachOwner(Self.owners)) == nil)
    }

    /// A mutant every one of its tests passed is decided too, and decided the expensive
    /// way round: `survived` is the answer that costs somebody work.
    @Test("stops once every mutant is either caught or cleared")
    func stopsWhenAllAreCleared() {
        let events =
            [Self.event(.runStarted)] + Self.failing("P.S/a1()")
            + Self.passing("P.S/b1()") + Self.passing("P.S/b2()")
        #expect(Self.stopsAfter(events, settling: .eachOwner(Self.owners)) == 7)
        #expect(events[7].kind == .testEnded)
    }

    /// The premise of the test above: one of the two tests passing is not enough.
    @Test("waits for the last of a mutant's tests")
    func waitsForTheLastTest() {
        let events =
            [Self.event(.runStarted)] + Self.failing("P.S/a1()") + Self.passing("P.S/b1()")
        #expect(Self.stopsAfter(events, settling: .eachOwner(Self.owners)) == nil)
    }

    /// A test nobody in the batch owns settles nobody. It is also the sign that the batch
    /// was built wrong, which the caller checks separately - here it must simply not be
    /// credited to anyone.
    @Test("lets a test that belongs to nobody decide nothing")
    func aStrangerDecidesNothing() {
        let events =
            [Self.event(.runStarted)] + Self.failing("P.S/a1()") + Self.passing("P.S/a2()")
            + Self.failing("P.S/elsewhere()")
        #expect(Self.stopsAfter(events, settling: .eachOwner(Self.owners)) == nil)
    }

    /// Nothing is assumed about tests that never report. A member whose tests the bundle
    /// never runs leaves the process running to its natural end, which is the answer this
    /// replaced and is always correct.
    @Test("runs to the end rather than deciding a mutant it never heard about")
    func neverHeardOf() {
        let events =
            [Self.event(.runStarted)] + Self.passing("P.S/a1()") + Self.passing("P.S/a2()")
            + [Self.event(.runEnded)]
        #expect(Self.stopsAfter(events, settling: .eachOwner(Self.owners)) == nil)
    }

    /// Watching one mutant is the same question with one owner, and the answer is the one
    /// it always was.
    @Test("still stops at the first failure when there is one mutant")
    func oneMutantIsUnchanged() {
        let events = [Self.event(.runStarted)] + Self.failing("P.S/a1()")
        #expect(Self.stopsAfter(events, settling: .oneMutant) == 2)
    }

    /// The baseline is not about a mutant at all: it is the whole suite, and it has to run.
    @Test("never stops early when the whole suite is the answer")
    func theWholeSuiteRuns() {
        let events =
            [Self.event(.runStarted)] + Self.failing("P.S/a1()") + Self.failing("P.S/b1()")
        #expect(Self.stopsAfter(events, settling: .wholeSuite) == nil)
    }

    /// What it decided, not just when. A batch's verdict still names every test that
    /// failed, because that is what the caller shares out among the mutants.
    @Test("still says which tests failed")
    func stillNamesTheKillers() {
        var watcher = StreamWatcher(settling: .eachOwner(Self.owners))
        for event in [Self.event(.runStarted)] + Self.failing("P.S/a1()")
            + Self.failing("P.S/b1()")
        {
            watcher.observe(event)
        }
        #expect(watcher.killers == ["P.S/a1()", "P.S/b1()"])
    }

    /// A known issue is an error by severity and not a failure. Settling a mutant on one
    /// would report it as killed by a test documented as currently failing.
    @Test("does not settle a mutant on an issue that is not a failure")
    func knownIssuesSettleNobody() {
        let events = [
            Self.event(.runStarted),
            Self.event(.testStarted, testID: "P.S/a1()"),
            Self.event(.issueRecorded, testID: "P.S/a1()", isFailure: false),
            Self.event(.testEnded, testID: "P.S/a1()"),
        ]
        var watcher = StreamWatcher(settling: .eachOwner(Self.owners))
        for event in events { watcher.observe(event) }
        #expect(watcher.killers.isEmpty)
        // One of a1's owner's two tests has ended, so nothing is settled either way.
        #expect(!watcher.isDecided)
    }
}

/// What a process that was stopped on purpose amounts to.
///
/// Stopping is how this tool saves most of what it saves, so the answer after a stop has to
/// be the answer, not a shrug. There are two kinds of stop and they mean opposite things: a
/// watcher that had learned everything it was waiting for stopped because it was done, and
/// one that had not was stopped by somebody else - a deadline, an interrupt - and knows
/// nothing.
@Suite("Stopping on purpose")
struct StoppedVerdictTests {

    static func watcher(
        _ events: [TestEvent], settling: StreamWatcher.Settlement
    ) -> StreamWatcher {
        var watcher = StreamWatcher(settling: settling)
        for event in events { watcher.observe(event) }
        return watcher
    }

    /// A batch every member of which passed its own tests. Nothing failed, the process was
    /// stopped because there was nothing left to learn, and every member survived. Calling
    /// that `errored` would throw away the answer and run them all again one at a time.
    @Test("calls a batch that cleared every mutant survived")
    func clearedEveryone() {
        let events =
            [SettlementTests.event(.runStarted)]
            + SettlementTests.passing("P.S/a1()") + SettlementTests.passing("P.S/a2()")
            + SettlementTests.passing("P.S/b1()") + SettlementTests.passing("P.S/b2()")
        let watcher = Self.watcher(events, settling: .eachOwner(SettlementTests.owners))
        #expect(watcher.isDecided)
        #expect(watcher.verdict(after: .stopped).outcome == .survived)
    }

    @Test("calls a batch that caught someone killed")
    func caughtSomeone() {
        let events =
            [SettlementTests.event(.runStarted)]
            + SettlementTests.failing("P.S/a1()")
            + SettlementTests.passing("P.S/b1()") + SettlementTests.passing("P.S/b2()")
        let watcher = Self.watcher(events, settling: .eachOwner(SettlementTests.owners))
        #expect(watcher.verdict(after: .stopped).outcome == .killed)
    }

    /// The other kind of stop. Nothing had been settled, so whoever stopped it knew
    /// something this does not, and the honest answer is that there is no answer.
    @Test("calls a stop it did not ask for errored")
    func aStopItDidNotAskFor() {
        let events = [SettlementTests.event(.runStarted)] + SettlementTests.passing("P.S/a1()")
        let watcher = Self.watcher(events, settling: .eachOwner(SettlementTests.owners))
        #expect(!watcher.isDecided)
        #expect(watcher.verdict(after: .stopped).outcome == .errored)
    }

    /// A process stopped before a single test began proves nothing, however decided it
    /// believes itself to be.
    @Test("proves nothing when no test ever started")
    func nothingStarted() {
        let watcher = Self.watcher(
            [SettlementTests.event(.runStarted)], settling: .eachOwner([:]))
        #expect(watcher.verdict(after: .stopped).outcome == .errored)
    }

    /// Watching one mutant is unchanged: a stop with a failure is a kill, and a stop
    /// without one is somebody else's doing.
    @Test("leaves one mutant's answer as it was")
    func oneMutantUnchanged() {
        let killed = Self.watcher(
            [SettlementTests.event(.runStarted)] + SettlementTests.failing("P.S/a1()"),
            settling: .oneMutant)
        #expect(killed.verdict(after: .stopped).outcome == .killed)

        let interrupted = Self.watcher(
            [SettlementTests.event(.runStarted)] + SettlementTests.passing("P.S/a1()"),
            settling: .oneMutant)
        #expect(interrupted.verdict(after: .stopped).outcome == .errored)
    }
}

/// Sharing one process's answer out among the mutants that were in it.
///
/// A batch runs several mutants at once and every one of them needs an answer about
/// itself. The tests are attributed by ownership, which is exact - no test reaches two
/// mutants in a batch, by construction. What was not exact was the message: every killed
/// member was given the *batch's* first failure, which is the first failure of whichever
/// mutant happened to be caught first.
@Suite("Sharing out a batch's answer")
struct BatchAttributionTests {

    static func verdict(killers: [String], firstFailure: String?) -> Verdict {
        Verdict(
            outcome: killers.isEmpty ? .survived : .killed,
            killedBy: killers,
            firstFailure: firstFailure,
            startedTests: ["P.S/a1()", "P.S/b1()"],
            durationMilliseconds: 1,
            termination: .stopped
        )
    }

    /// The mutant whose own test failed first gets the message, because it is about it.
    @Test("gives the message to the mutant it is about")
    func theRightOwner() {
        let said = Scheduler.message(
            of: 1,
            killedBy: ["P.S/a1()"],
            in: Self.verdict(killers: ["P.S/a1()", "P.S/b1()"], firstFailure: "a1 failed")
        )
        #expect(said == "a1 failed")
    }

    /// And the other one gets nothing rather than somebody else's words. A report that put
    /// one mutant's failure against another is a report that sends a reader to the wrong
    /// assertion.
    @Test("gives nothing to the mutant it is not about")
    func theWrongOwner() {
        #expect(
            Scheduler.message(
                of: 2,
                killedBy: ["P.S/b1()"],
                in: Self.verdict(killers: ["P.S/a1()", "P.S/b1()"], firstFailure: "a1 failed")
            ) == nil
        )
    }

    @Test("gives nothing to a mutant nothing caught")
    func theSurvivor() {
        #expect(
            Scheduler.message(
                of: 3,
                killedBy: [],
                in: Self.verdict(killers: ["P.S/a1()"], firstFailure: "a1 failed")
            ) == nil
        )
    }

    /// One mutant in a process is the ordinary case, and the message is its own.
    @Test("gives the message to the only mutant there was")
    func theOnlyOne() {
        let said = Scheduler.message(
            of: 1,
            killedBy: ["P.S/a1()"],
            in: Self.verdict(killers: ["P.S/a1()"], firstFailure: "a1 failed")
        )
        #expect(said == "a1 failed")
    }
}
