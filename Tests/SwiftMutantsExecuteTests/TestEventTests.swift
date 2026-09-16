// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsExecute

/// Reading what a test bundle says while it is still saying it.
///
/// swift-testing writes one JSON object per line and, pointed at a named pipe, writes each
/// as it happens. That is what lets a mutant cost "time to the first failure" rather than
/// "time for the whole suite": the moment a failure arrives the answer is known and the
/// process tree can go.
///
/// The field that decides is `isFailure`, and nothing else. Measured against the pinned
/// toolchain: a `withKnownIssue` block records an issue with `severity: "error"` and
/// `isFailure: false`. A tool that keyed on severity would report a mutant as killed by a
/// test that is *documented as currently failing* - a kill that says nothing about the
/// mutant, credited to a test that never passed.
@Suite("Test events")
struct TestEventTests {

    static let failure = """
        {"kind":"event","payload":{"kind":"issueRecorded","testID":"P.S/f()/S.swift:7:6",\
        "issue":{"isFailure":true,"isKnown":false,"severity":"error"},\
        "messages":[{"symbol":"fail","text":"Expectation failed: 3 == 4"}]},"version":0}
        """

    static let knownIssue = """
        {"kind":"event","payload":{"kind":"issueRecorded","testID":"P.S/w()/S.swift:8:6",\
        "issue":{"isFailure":false,"isKnown":true,"severity":"error"},\
        "messages":[{"symbol":"fail","text":"Expectation failed: 3 == 5"}]},"version":0}
        """

    /// The line a disabled suite writes, taken from this toolchain's own output for a
    /// `@Suite(..., .enabled(if:))` whose condition was false.
    static let stepAside = """
        {"kind":"event","payload":{"kind":"testSkipped",\
        "testID":"P.NeedsRepository/alphabet()"},"version":0}
        """

    /// Reading it is a separate claim from acting on it, and only this one is about the
    /// wire. A watcher given a `.testSkipped` value would go on doing the right thing
    /// while the parser called it `.other` and dropped it - which is precisely the state
    /// this tool was in, and a test built from values rather than lines could not see.
    @Test("reads a test that stepped aside")
    func readsASkip() throws {
        let event = try #require(TestEvent(line: Self.stepAside))
        #expect(event.kind == .testSkipped)
        #expect(event.testID == "P.NeedsRepository/alphabet()")
        #expect(!event.isFailure)
    }

    @Test("reads a failure")
    func readsAFailure() throws {
        let event = try #require(TestEvent(line: Self.failure))
        #expect(event.kind == .issueRecorded)
        #expect(event.isFailure)
        #expect(!event.isKnown)
        #expect(event.testID == "P.S/f()/S.swift:7:6")
        #expect(event.message == "Expectation failed: 3 == 4")
    }

    /// The one that matters. A known issue is an error by severity and not a failure, and
    /// only the second of those two facts is about whether the mutant was caught.
    @Test("does not take a known issue for a failure")
    func knownIssueIsNotAFailure() throws {
        let event = try #require(TestEvent(line: Self.knownIssue))
        #expect(event.kind == .issueRecorded)
        #expect(!event.isFailure)
        #expect(event.isKnown)
    }

    /// Swift 6.3 lets an issue be a warning (ST-0013). A warning is not a failure either,
    /// and the same field says so.
    @Test("does not take a warning for a failure")
    func warningIsNotAFailure() throws {
        let event = try #require(
            TestEvent(
                line: """
                    {"kind":"event","payload":{"kind":"issueRecorded","testID":"P.S/f()",\
                    "issue":{"isFailure":false,"isKnown":false,"severity":"warning"}}}
                    """
            )
        )
        #expect(!event.isFailure)
    }

    @Test(
        "reads the kinds it acts on",
        arguments: [
            ("runStarted", TestEvent.Kind.runStarted),
            ("testStarted", .testStarted),
            ("testEnded", .testEnded),
            ("issueRecorded", .issueRecorded),
            ("runEnded", .runEnded),
            ("valueAttached", .other),
        ])
    func kinds(spelled: String, kind: TestEvent.Kind) throws {
        let event = try #require(
            TestEvent(line: #"{"kind":"event","payload":{"kind":"\#(spelled)"}}"#))
        #expect(event.kind == kind)
    }

    /// A test declaration is not an event. Taking one for an event would be reading a
    /// description of a test as something that happened to it.
    @Test("reads nothing out of a line that is not an event")
    func notAnEvent() {
        #expect(TestEvent(line: #"{"kind":"test","payload":{"kind":"function"}}"#) == nil)
    }

    /// A stream read from a pipe ends wherever the writer stopped, which may be mid-line
    /// if the writer was killed. A half-written line is not an event.
    @Test(
        "reads nothing out of what is not a line of JSON",
        arguments: [
            "",
            "   ",
            "{",
            #"{"kind":"event","payload":{"kind":"issueRe"#,
            "not json at all",
            "[]",
            #"{"payload":{"kind":"runEnded"}}"#,
        ])
    func refusesRubbish(line: String) {
        #expect(TestEvent(line: line) == nil, "parsed: \(line)")
    }

    /// Reported without the position, which is a fact about the test file rather than
    /// about the mutant, and would make two runs of the same mutant differ if a test moved.
    @Test("keeps the identifier a test is known by")
    func keepsTheIdentifier() throws {
        let event = try #require(TestEvent(line: Self.failure))
        #expect(event.testID == "P.S/f()/S.swift:7:6")
    }
}
