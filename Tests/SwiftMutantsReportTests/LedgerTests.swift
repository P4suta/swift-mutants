// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsReport

/// Answers written down as they are decided, rather than all at once at the end.
///
/// A report is written once, when the run finishes. So a run killed a second before that is
/// indistinguishable from a run that never started: every answer existed, an hour of work
/// had been done, and the output is the same nothing. Reported from a package of 755 mutants
/// where the harness stopped the run for memory pressure at 755 of 755 - after the last
/// answer was in and before the summary was rendered.
///
/// The shape is the probe log's, and for the same reason: append-only, opened once, never
/// closed, one line per answer written the moment it is known. What was written before a
/// process died is what it proved, with no flush window and no handler that has to run.
///
/// It is not a second report. It is the answers, in the order they arrived, so that a run
/// somebody stopped is still a run somebody can read.
@Suite("Answers written down as they arrive")
struct LedgerTests {

    static func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "swift-mutants-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func answer(_ identity: String, outcome: String = "survived") -> Ledger.Answer {
        Ledger.Answer(
            identity: String(repeating: identity, count: 64 / identity.count),
            path: "Sources/A.swift",
            rule: "lt-to-le@1",
            outcome: outcome,
            killedBy: outcome == "killed" ? ["P.S/f()"] : [],
            durationMilliseconds: 12
        )
    }

    @Test("keeps an answer the moment it is known")
    func keepsOne() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }

        let ledger = try #require(Ledger(at: home.appending(path: "run.jsonl")))
        ledger.record(Self.answer("a"))
        #expect(Ledger.read(home.appending(path: "run.jsonl")).count == 1)
    }

    /// In the order they arrived, which is the order the workers finished rather than
    /// catalogue order. Whoever reads it is reading what happened, not a report.
    @Test("keeps them in the order they arrived")
    func keepsOrder() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: "run.jsonl")

        let ledger = try #require(Ledger(at: file))
        ledger.record(Self.answer("c"))
        ledger.record(Self.answer("a"))
        ledger.record(Self.answer("b", outcome: "killed"))

        let read = Ledger.read(file)
        #expect(read.map { $0.identity.prefix(1) } == ["c", "a", "b"])
        #expect(read.last?.outcome == "killed")
    }

    /// A line written by a process that died part way through writing it is not an answer.
    /// Taking the readable part of it would be taking a smaller answer, which is exactly
    /// the shape of a wrong one.
    @Test("reads nothing out of a line that was cut off")
    func halfWritten() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: "run.jsonl")

        let ledger = try #require(Ledger(at: file))
        ledger.record(Self.answer("a"))
        try (try String(contentsOf: file, encoding: .utf8) + "{\"identity\":\"b").write(
            to: file, atomically: true, encoding: .utf8)

        #expect(Ledger.read(file).count == 1)
    }

    /// Nothing there is not a failure. Most runs finish, and a finished run's ledger is
    /// taken away by the report that supersedes it.
    @Test("reads nothing out of a file that is not there")
    func absent() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(Ledger.read(home.appending(path: "nothing.jsonl")).isEmpty)
    }

    /// Several workers answer at once, so every line arrives from a different task. A line
    /// is written with one `write`, which the kernel does not interleave for a size like
    /// this - the same guarantee the probe log rests on.
    @Test("is safe to write from several workers at once")
    func concurrent() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: "run.jsonl")
        let ledger = try #require(Ledger(at: file))

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for _ in 0..<32 { ledger.record(Self.answer("\(worker % 8)")) }
                }
            }
        }
        #expect(Ledger.read(file).count == 8 * 32)
    }
}
