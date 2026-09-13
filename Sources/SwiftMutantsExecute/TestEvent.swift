// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// One thing a test bundle said while it was running.
///
/// swift-testing writes its event stream as JSON Lines - one object per line, each written
/// as it happens. Pointed at a named pipe, that makes it a stream rather than a report, and
/// a stream is what lets a mutant cost "time to the first failure" instead of "time for the
/// whole suite".
///
/// Only the fields a decision rests on are read. The stream carries timings, source
/// locations and structured messages as well, and none of them says whether the mutant was
/// caught; a decoder that modelled all of it would be a decoder that breaks whenever the
/// format gains a field.
public struct TestEvent: Sendable, Hashable {

    /// The kinds this tool acts on.
    ///
    /// Everything else is ``other``: the stream is allowed to grow new kinds, and a run
    /// must not fail because it did.
    public enum Kind: Sendable, Hashable {
        case runStarted
        case testStarted
        case testEnded
        case issueRecorded
        case runEnded
        case other
    }

    /// What happened.
    public let kind: Kind

    /// Which test it happened to, as swift-testing names it.
    public let testID: String?

    /// Whether this issue means a test failed.
    ///
    /// **The field that decides a kill, and the only one.** Measured against the pinned
    /// toolchain: a `withKnownIssue` block records an issue with `severity: "error"` and
    /// `isFailure: false`. A tool that keyed on severity would report a mutant as killed
    /// by a test documented as currently failing - a kill that says nothing about the
    /// mutant. Since Swift 6.3 an issue may also be a warning (ST-0013), and that is not a
    /// failure either. Both cases come out of this one field.
    public let isFailure: Bool

    /// Whether the issue was one the test said it expected.
    ///
    /// Kept for the report rather than for the decision: a suite full of known issues is
    /// worth seeing, and it is not the same thing as a suite that passed.
    public let isKnown: Bool

    /// The first thing it said, if it said anything.
    public let message: String?
}

extension TestEvent {

    /// Reads one line of the event stream, or nothing if the line is not one.
    ///
    /// Nothing rather than an error, and per line rather than per stream. A pipe ends
    /// wherever its writer stopped, which is mid-line whenever the writer was killed -
    /// which is exactly what this tool does to it on the first failure. A half-written
    /// line is not an event and must not be one.
    public init?(line: String) {
        guard
            let top = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            top["kind"] as? String == "event",
            let payload = top["payload"] as? [String: Any],
            let spelled = payload["kind"] as? String
        else { return nil }

        let issue = payload["issue"] as? [String: Any]
        let messages = payload["messages"] as? [[String: Any]]
        self.init(
            kind: Kind(spelled),
            testID: payload["testID"] as? String,
            isFailure: issue?["isFailure"] as? Bool ?? false,
            isKnown: issue?["isKnown"] as? Bool ?? false,
            message: messages?.first?["text"] as? String
        )
    }
}

extension TestEvent.Kind {
    /// Reads a kind the stream spelled, keeping anything unfamiliar as ``other``.
    ///
    /// The stream is allowed to grow new kinds, and a run must not fail because it did.
    init(_ spelled: String) {
        switch spelled {
        case "runStarted": self = .runStarted
        case "testStarted": self = .testStarted
        case "testEnded": self = .testEnded
        case "issueRecorded": self = .issueRecorded
        case "runEnded": self = .runEnded
        default: self = .other
        }
    }
}
