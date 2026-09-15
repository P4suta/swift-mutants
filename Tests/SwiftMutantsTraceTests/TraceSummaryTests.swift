// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsTrace

/// Where a run's time went.
///
/// A mutation run takes long enough that "it was slow" is the most common thing anybody has
/// to say about one, and there was no way to answer it. Every subprocess was already
/// recorded with what it cost - the recording is a choke point that callers cannot forget -
/// and nothing read it back.
///
/// By what the commands were rather than by phase, because the phases are already printed
/// as they happen and the question left over is which *kind* of work the time went into.
/// Compiles and trials are the two answers that matter and they want opposite responses: a
/// run that is mostly compiles wants fewer rounds, and a run that is mostly trials wants
/// better coverage or a wider machine.
///
/// Durations and never timestamps. Two runs of the same package should differ only where
/// they did different work, and a summary carrying a clock could not be diffed against
/// yesterday's.
@Suite("Where a run's time went")
struct TraceSummaryTests {

    static func exec(_ label: String, _ milliseconds: Int, exit: Int = 0) -> TraceEvent {
        TraceEvent(
            sequence: 0,
            kind: .exec(
                TraceEvent.Execution(
                    label: label,
                    arguments: [label],
                    directory: "/pkg",
                    environmentNames: [],
                    timeoutMilliseconds: nil,
                    exitCode: exit,
                    durationMilliseconds: milliseconds,
                    standardOutputDigest: nil,
                    standardOutputBytes: 0,
                    failure: nil
                )))
    }

    static let run = [
        exec("build", 40_000),
        exec("typecheck", 12_000),
        exec("typecheck", 8_000),
        exec("mutant", 500),
        exec("mutant", 700),
        exec("mutant", 300, exit: 1),
    ]

    /// The biggest first, because the first line is the answer for most people.
    @Test("puts the kind that took longest first")
    func biggestFirst() {
        let rows = TraceSummary.of(Self.run)
        #expect(rows.first?.label == "build")
        #expect(rows.first?.milliseconds == 40_000)
    }

    /// Added up per kind, because one compile of forty seconds and forty of one second are
    /// different situations wanting different answers, and the count is what tells them
    /// apart.
    @Test("adds up each kind and counts it")
    func addsUp() {
        let rows = TraceSummary.of(Self.run)
        let typechecks = rows.first { $0.label == "typecheck" }
        #expect(typechecks?.milliseconds == 20_000)
        #expect(typechecks?.count == 2)
    }

    /// A command that failed is still time spent, and often most of it: the expensive
    /// failure is the one that took twenty minutes to say no.
    @Test("counts the ones that failed as time spent")
    func failuresCount() {
        let mutants = TraceSummary.of(Self.run).first { $0.label == "mutant" }
        #expect(mutants?.count == 3)
        #expect(mutants?.milliseconds == 1_500)
    }

    /// And says how many of them failed, because a hundred trials of which ninety failed is
    /// a different run from a hundred of which none did.
    @Test("says how many of each kind failed")
    func saysHowManyFailed() {
        #expect(TraceSummary.of(Self.run).first { $0.label == "mutant" }?.failed == 1)
    }

    /// A run with nothing recorded is a run that started nothing, which is an answer rather
    /// than an error.
    @Test("says nothing about a run that started nothing")
    func nothingRecorded() {
        #expect(TraceSummary.of([]).isEmpty)
    }
}
