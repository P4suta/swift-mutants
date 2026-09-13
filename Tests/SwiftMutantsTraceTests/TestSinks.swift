// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Synchronization

@testable import SwiftMutantsTrace

/// A sink that remembers what it was given, for tests that assert on the stream.
final class CollectingSink: TraceSink, Sendable {
    private let recorded = Mutex<[TraceEvent]>([])

    func record(_ event: TraceEvent) throws {
        recorded.withLock { $0.append(event) }
    }

    func events() -> [TraceEvent] {
        recorded.withLock { $0 }
    }
}

/// A sink that always fails, for the property that a failing one costs a note and not the
/// run.
final class FailingSink: TraceSink, Sendable {
    struct Refusal: Error, CustomStringConvertible {
        let description = "the disk said no"
    }

    func record(_ event: TraceEvent) throws {
        throw Refusal()
    }
}
