// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsTrace
import Testing

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

    @Test("puts the kind that took longest first")
    func biggestFirst() {
        let rows = TraceSummary.of(Self.run)
        #expect(rows.first?.label == "build")
        #expect(rows.first?.milliseconds == 40_000)
    }

    @Test("adds up each kind and counts it")
    func addsUp() {
        let rows = TraceSummary.of(Self.run)
        let typechecks = rows.first { $0.label == "typecheck" }
        #expect(typechecks?.milliseconds == 20_000)
        #expect(typechecks?.count == 2)
    }

    @Test("counts the ones that failed as time spent")
    func failuresCount() {
        let mutants = TraceSummary.of(Self.run).first { $0.label == "mutant" }
        #expect(mutants?.count == 3)
        #expect(mutants?.milliseconds == 1_500)
    }

    @Test("says how many of each kind failed")
    func saysHowManyFailed() {
        #expect(TraceSummary.of(Self.run).first { $0.label == "mutant" }?.failed == 1)
    }

    @Test("says nothing about a run that started nothing")
    func nothingRecorded() {
        #expect(TraceSummary.of([]).isEmpty)
    }

    @Test("public summary formatting preserves counts, shares, failures, and durations")
    func formattedLines() {
        #expect(TraceSummary.lines(of: []) == ["this run started nothing."])
        #expect(
            TraceSummary.lines(of: Self.run) == [
                "  build           40s  65%  1 run",
                "  typecheck       20s  32%  2 runs",
                "  mutant          1s  2%  3 runs, 1 of them failed",
            ])
        #expect(
            TraceSummary.lines(of: [Self.exec("long-operation", 61_000)]) == [
                "  long-operation  1m1s  100%  1 run"
            ])
    }
}
