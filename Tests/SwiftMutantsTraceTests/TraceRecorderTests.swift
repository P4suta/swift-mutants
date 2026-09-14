// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsTrace

/// Where a run's account is kept while the run is happening.
///
/// Recording is unconditional. Without `--trace` the events go into a bounded ring in
/// memory and are written out only if the run fails; with it, they also go to a file as
/// they happen. The flag changes where the account goes, never whether there is one,
/// because the failure nobody expected is exactly the failure nobody passed a flag for.
@Suite("Trace recorder")
struct TraceRecorderTests {

    @Test("numbers events from one, densely")
    func sequenceIsDenseAndOneBased() {
        let recorder = TraceRecorder(retaining: 16)
        let first = recorder.record(.phaseBegan(phase: "a"))
        let second = recorder.record(.phaseBegan(phase: "b"))
        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(recorder.retainedEvents().map(\.sequence) == [1, 2])
    }

    /// Workers record concurrently, and a reader has to be able to tell whether the account
    /// is complete. A gap or a repeat in the numbering would make that impossible.
    @Test("numbers events densely even when many workers record at once")
    func sequenceSurvivesConcurrency() async {
        let recorder = TraceRecorder(retaining: 4096)
        let count = 1000
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask { recorder.record(.phaseBegan(phase: "phase-\(index)")) }
            }
        }
        let sequences = recorder.retainedEvents().map(\.sequence).sorted()
        #expect(sequences == Array(1...count))
        #expect(recorder.totalRecorded() == count)
    }

    /// An always-on recording cannot grow without limit, so the ring keeps the most recent
    /// events and says how many there were. A reader who sees fewer events than the total
    /// knows the account is a tail rather than the whole thing.
    @Test("keeps the most recent events and reports how many there were")
    func ringIsBoundedAndHonestAboutIt() {
        let recorder = TraceRecorder(retaining: 3)
        for index in 1...10 {
            recorder.record(.phaseBegan(phase: "phase-\(index)"))
        }
        #expect(recorder.retainedEvents().map(\.sequence) == [8, 9, 10])
        #expect(recorder.totalRecorded() == 10)
    }

    @Test("hands every event to every sink, in order")
    func sinksSeeEverything() {
        let first = CollectingSink()
        let second = CollectingSink()
        let recorder = TraceRecorder(retaining: 8, sinks: [first, second])
        recorder.record(.phaseBegan(phase: "a"))
        recorder.record(.phaseEnded(phase: "a", durationMilliseconds: 3))
        recorder.record(.runEnded(outcome: "completed"))

        #expect(first.events().map(\.sequence) == [1, 2, 3])
        #expect(second.events().map(\.sequence) == [1, 2, 3])
    }

    /// A trace is never evidence, so a sink that cannot do its job costs a note and not the
    /// run. The other sinks still see the event, and the ring still holds it.
    @Test("keeps recording when a sink fails")
    func aFailingSinkDoesNotStopTheRun() {
        let broken = FailingSink()
        let working = CollectingSink()
        let recorder = TraceRecorder(retaining: 8, sinks: [broken, working])
        recorder.record(.phaseBegan(phase: "a"))
        recorder.record(.phaseBegan(phase: "b"))

        #expect(working.events().count == 2)
        #expect(recorder.retainedEvents().count == 2)
        #expect(recorder.sinkFailures() == ["the disk said no"])
    }

    /// A recorder with no ring at all is what a run uses when it has been told to record
    /// nowhere. It still numbers events, so a sink attached later sees a consistent stream.
    @Test("still numbers events when it retains none")
    func retainsNothingButStillNumbers() {
        let sink = CollectingSink()
        let recorder = TraceRecorder(retaining: 0, sinks: [sink])
        recorder.record(.phaseBegan(phase: "a"))
        recorder.record(.phaseBegan(phase: "b"))
        #expect(recorder.retainedEvents().isEmpty)
        #expect(recorder.totalRecorded() == 2)
        #expect(sink.events().map(\.sequence) == [1, 2])
    }
}
