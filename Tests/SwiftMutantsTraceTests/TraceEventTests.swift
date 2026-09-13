// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsTrace

/// What a run writes down about itself.
///
/// Every run records, whether or not anybody asked: the failure nobody expected is exactly
/// the failure nobody passed `--trace` for. Without a flag the account is kept in memory;
/// with one it is written out. Either way it is the same events in the same order.
///
/// A trace is never evidence. It takes no part in a verdict, in a mutant's identity, or in
/// a cache key, and one that cannot be written costs a warning rather than the run.
@Suite("Trace event")
struct TraceEventTests {

    static func line(_ event: TraceEvent) throws -> String {
        String(decoding: try event.jsonLine(), as: UTF8.self)
    }

    @Test("writes one JSON object per line, with no line breaks inside it")
    func oneObjectPerLine() throws {
        let event = TraceEvent(
            sequence: 1,
            kind: .phaseBegan(phase: "snapshot")
        )
        let line = try Self.line(event)
        #expect(line == #"{"kind":"phase-begin","phase":"snapshot","seq":1}"#)
        #expect(!line.contains("\n"))
    }

    /// Durations, never timestamps. Two runs of the same tree should differ only where the
    /// run differed, so that `trace diff` shows what changed rather than showing that time
    /// passed.
    @Test("records how long a phase took, not when it happened")
    func durationsNotTimestamps() throws {
        let line = try Self.line(
            TraceEvent(sequence: 2, kind: .phaseEnded(phase: "snapshot", durationMilliseconds: 231))
        )
        #expect(line == #"{"duration_ms":231,"kind":"phase-end","phase":"snapshot","seq":2}"#)
    }

    /// A diagnostics bundle is something people attach to a bug report, so the account
    /// records which variables a child process was given and never what was in them.
    @Test("records the names of environment variables and not their values")
    func environmentNamesOnly() throws {
        let execution = TraceEvent.Execution(
            label: "swift-build",
            arguments: ["swift", "build", "--build-tests"],
            directory: "/tmp/snap/tree",
            environmentNames: ["PATH", "SWIFT_MUTANTS_ACTIVE", "AWS_SECRET_ACCESS_KEY"],
            timeoutMilliseconds: 60000,
            exitCode: 0,
            durationMilliseconds: 231,
            standardOutputDigest: Digest.of("build output"),
            standardOutputBytes: 4821,
            failure: nil
        )
        let line = try Self.line(TraceEvent(sequence: 3, kind: .exec(execution)))
        #expect(
            line.contains(#""env_names":["PATH","SWIFT_MUTANTS_ACTIVE","AWS_SECRET_ACCESS_KEY"]"#))
        #expect(!line.contains("secret-value"))
    }

    /// A command that never became a process is precisely what a reader needs to be told
    /// about, so it is recorded rather than dropped: exit -1, and the refusal as the
    /// event's failure.
    @Test("records a command that could not be started")
    func recordsACommandThatNeverRan() throws {
        let execution = TraceEvent.Execution(
            label: "swift-build",
            arguments: ["swift", "build"],
            directory: "/tmp/snap/tree",
            environmentNames: ["PATH"],
            timeoutMilliseconds: nil,
            exitCode: -1,
            durationMilliseconds: 0,
            standardOutputDigest: nil,
            standardOutputBytes: 0,
            failure: "no such file or directory"
        )
        let line = try Self.line(TraceEvent(sequence: 4, kind: .exec(execution)))
        #expect(line.contains(#""exit":-1"#))
        #expect(line.contains(#""failure":"no such file or directory""#))
    }

    @Test("round-trips every kind it can record")
    func roundTripsEveryKind() throws {
        let events: [TraceEvent.Kind] = [
            .runStarted(runIdentifier: "20260914T011213Z-67af", toolVersion: "0.0.0"),
            .phaseBegan(phase: "discover"),
            .phaseEnded(phase: "discover", durationMilliseconds: 12),
            .exec(
                TraceEvent.Execution(
                    label: "swift-test",
                    arguments: ["swift", "test"],
                    directory: ".",
                    environmentNames: ["PATH"],
                    timeoutMilliseconds: 1000,
                    exitCode: 1,
                    durationMilliseconds: 5,
                    standardOutputDigest: Digest.of("x"),
                    standardOutputBytes: 1,
                    failure: nil
                )
            ),
            .warning(code: "SWM1013", message: "trace directory refused; recording in memory"),
            .runEnded(outcome: "completed"),
        ]
        for (index, kind) in events.enumerated() {
            let event = TraceEvent(sequence: index + 1, kind: kind)
            let decoded = try JSONDecoder().decode(TraceEvent.self, from: try event.jsonLine())
            #expect(decoded == event, "\(kind) did not survive the round trip")
        }
    }

    /// A reader of an old recording must not be stopped by a kind a newer build records.
    /// Ignoring the line is the only behaviour that lets `trace diff` work across versions.
    @Test("refuses a kind it does not know, without refusing the stream")
    func unknownKindIsRefusedAlone() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                TraceEvent.self,
                from: Data(#"{"seq":1,"kind":"from-the-future"}"#.utf8)
            )
        }
    }

    @Test("refuses a sequence number that cannot be one")
    func refusesNonPositiveSequence() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                TraceEvent.self,
                from: Data(#"{"seq":0,"kind":"phase-begin","phase":"x"}"#.utf8)
            )
        }
    }
}
