// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Synchronization

/// Somewhere a recorded event goes.
///
/// A sink may fail. The recorder catches it, keeps the note, and carries on - a trace is
/// never evidence, so a recording that cannot be written costs a warning rather than the
/// run it was a recording of.
public protocol TraceSink: Sendable {
    /// Writes one event down.
    func record(_ event: TraceEvent) throws
}

/// The account a run keeps of itself while it is happening.
///
/// Recording is unconditional. Without `--trace` events go into a bounded ring in memory
/// and are written out only if the run fails; with it they also reach a file as they
/// happen. The flag changes where the account goes, never whether there is one, because
/// the failure nobody expected is exactly the failure nobody passed a flag for.
///
/// Numbering is dense and one-based even under concurrent recording, so that a reader can
/// tell a complete account from a tail of one: fewer retained events than
/// ``totalRecorded()`` means the ring wrapped, and a gap in the numbering would mean
/// something worse.
public final class TraceRecorder: Sendable {

    private struct State {
        var nextSequence = 1
        var retained: [TraceEvent] = []
        var totalRecorded = 0
        var sinkFailures: [String] = []
    }

    private let state = Mutex(State())
    private let capacity: Int
    private let sinks: [any TraceSink]

    /// Creates a recorder that keeps the most recent `retaining` events.
    ///
    /// The ring is bounded because the recording is always on: an account that grew with
    /// the run would make a long run pay for a diagnostic nobody asked for.
    public init(retaining capacity: Int = 512, sinks: [any TraceSink] = []) {
        self.capacity = max(0, capacity)
        self.sinks = sinks
    }

    /// Records one event and returns it, numbered.
    @discardableResult
    public func record(_ kind: TraceEvent.Kind) -> TraceEvent {
        let event = state.withLock { state in
            let event = TraceEvent(sequence: state.nextSequence, kind: kind)
            state.nextSequence += 1
            state.totalRecorded += 1
            if capacity > 0 {
                state.retained.append(event)
                if state.retained.count > capacity {
                    state.retained.removeFirst(state.retained.count - capacity)
                }
            }
            return event
        }

        for sink in sinks {
            do {
                try sink.record(event)
            } catch {
                let note = String(describing: error)
                state.withLock { state in
                    if !state.sinkFailures.contains(note) {
                        state.sinkFailures.append(note)
                    }
                }
            }
        }
        return event
    }

    /// The events still in the ring, oldest first.
    public func retainedEvents() -> [TraceEvent] {
        state.withLock { $0.retained }
    }

    /// How many events were recorded, including any the ring has since dropped.
    public func totalRecorded() -> Int {
        state.withLock { $0.totalRecorded }
    }

    /// What the sinks complained about, each reason once.
    ///
    /// Read by the run at the end, so that a recording nobody could write becomes one
    /// warning rather than one per event.
    public func sinkFailures() -> [String] {
        state.withLock { $0.sinkFailures }
    }
}
