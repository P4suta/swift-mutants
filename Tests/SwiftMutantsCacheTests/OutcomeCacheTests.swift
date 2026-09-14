// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsCache

/// Remembering an answer, and refusing to remember the wrong ones.
///
/// Only three outcomes may be stored: `killed`, `survived`, and a timeout confirmed by a
/// serial retry. Everything else is a statement about the machine rather than about the
/// program - a mutant that errored, a mutant that ran out of time once on a busy laptop, a
/// mutant somebody interrupted - and a cache that kept those would turn a bad afternoon
/// into a permanent answer.
@Suite("Outcome cache")
struct OutcomeCacheTests {

    static func key(_ name: String) -> Digest { Digest.of(name) }

    /// Enough names that their digests are not already in order.
    static let keys = ["a", "b", "c", "d", "e", "f"]

    static func answered(_ outcome: Outcome, by killers: [String] = []) -> CachedAnswer {
        CachedAnswer(
            outcome: outcome,
            killedBy: killers,
            testsStarted: killers.count,
            durationMilliseconds: 12
        )
    }

    @Test("gives back what it was told")
    func remembers() {
        let cache = OutcomeCache().recording(Self.key("a"), Self.answered(.killed, by: ["t"]))
        #expect(cache.answer(for: Self.key("a"))?.outcome == .killed)
        #expect(cache.answer(for: Self.key("a"))?.killedBy == ["t"])
    }

    @Test("has nothing to say about a question it was never asked")
    func knowsNothingElse() {
        let cache = OutcomeCache().recording(Self.key("a"), Self.answered(.killed))
        #expect(cache.answer(for: Self.key("b")) == nil)
    }

    /// The keys are different questions, so both answers are kept.
    @Test("holds more than one answer")
    func holdsMany() {
        let cache = OutcomeCache()
            .recording(Self.key("a"), Self.answered(.killed))
            .recording(Self.key("b"), Self.answered(.survived))
        #expect(cache.answer(for: Self.key("a"))?.outcome == .killed)
        #expect(cache.answer(for: Self.key("b"))?.outcome == .survived)
        #expect(cache.count == 2)
    }

    /// A key names everything the answer rests on, so the same key twice is the same
    /// question twice - and the newer answer is the one that was measured most recently.
    @Test("keeps the newer answer to the same question")
    func newerWins() {
        let cache = OutcomeCache()
            .recording(Self.key("a"), Self.answered(.survived))
            .recording(Self.key("a"), Self.answered(.killed, by: ["t"]))
        #expect(cache.answer(for: Self.key("a"))?.outcome == .killed)
        #expect(cache.count == 1)
    }

    @Test(
        "remembers only what is about the program",
        arguments: [Outcome.killed, .survived, .timedOut]
    )
    func remembersRealAnswers(_ outcome: Outcome) {
        let cache = OutcomeCache().recording(Self.key("a"), Self.answered(outcome))
        #expect(cache.answer(for: Self.key("a"))?.outcome == outcome)
    }

    /// A bad afternoon must not become a permanent answer.
    @Test(
        "refuses what is about the machine",
        arguments: [Outcome.errored, .inconclusive, .notRun, .rejected, .equivalent]
    )
    func refusesMachineAnswers(_ outcome: Outcome) {
        let cache = OutcomeCache().recording(Self.key("a"), Self.answered(outcome))
        #expect(cache.answer(for: Self.key("a")) == nil)
        #expect(cache.isEmpty)
    }
}

/// Keeping answers between runs.
///
/// A cache that cannot survive the process is not a cache. A cache that cannot survive a
/// *corrupt* file is worse than none: half a file of answers is exactly the shape of "a
/// few mutants were quietly skipped", which is the one failure this tool must never have.
@Suite("A cache on disk")
struct CacheStorageTests {

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-cache-\(UUID().uuidString)")
    }

    @Test("comes back the way it went in")
    func roundTrips() throws {
        let file = Self.scratch().appending(path: "outcomes.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let cache = OutcomeCache()
            .recording(OutcomeCacheTests.key("a"), OutcomeCacheTests.answered(.killed, by: ["t"]))
            .recording(OutcomeCacheTests.key("b"), OutcomeCacheTests.answered(.survived))
        try cache.write(to: file)

        let again = OutcomeCache.read(from: file)
        #expect(again.count == 2)
        #expect(again.answer(for: OutcomeCacheTests.key("a"))?.killedBy == ["t"])
        #expect(again.answer(for: OutcomeCacheTests.key("b"))?.outcome == .survived)
    }

    @Test("writes a file that was not there")
    func makesTheDirectory() throws {
        let file = Self.scratch().appending(path: "nested/outcomes.json")
        defer {
            try? FileManager.default.removeItem(
                at: file.deletingLastPathComponent().deletingLastPathComponent())
        }
        try OutcomeCache().recording(
            OutcomeCacheTests.key("a"), OutcomeCacheTests.answered(.killed)
        )
        .write(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Nothing there is not an error: it is the first run.
    @Test("reads an empty cache out of a file that is not there")
    func nothingThere() {
        #expect(OutcomeCache.read(from: Self.scratch().appending(path: "nope.json")).isEmpty)
    }

    /// A file half-written by an interrupted run reads as no cache at all, because a few
    /// answers out of a corrupt file is exactly the shape of "some mutants were quietly
    /// skipped". Measuring again is cheap; being wrong is not.
    @Test(
        "reads nothing out of a file it cannot trust",
        arguments: [
            "", "{", "[]", "not json at all",
            // A version this build does not know. Shaped correctly and full of answers,
            // which is the point: it is not upgraded, it is ignored.
            """
            {"version":99,"answers":{"aa":{"outcome":"killed","killedBy":["t"],\
            "testsStarted":1,"durationMilliseconds":1}}}
            """,
        ]
    )
    func refusesWhatItCannotTrust(_ contents: String) throws {
        let file = Self.scratch().appending(path: "outcomes.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data(contents.utf8).write(to: file)

        #expect(OutcomeCache.read(from: file).isEmpty)
    }

    /// Two runs of the same package write the same bytes, so a cache can be diffed and
    /// checked in if somebody wants to.
    ///
    /// Asserted as sortedness rather than as "twice is the same", because a dictionary
    /// enumerates in one order within a process and a different one in the next: comparing
    /// two encodings here would pass however this was written, and only fail on somebody
    /// else's machine.
    @Test("writes its answers in one order")
    func deterministicBytes() throws {
        let cache = OutcomeCacheTests.keys.reduce(OutcomeCache()) {
            $0.recording(OutcomeCacheTests.key($1), OutcomeCacheTests.answered(.survived))
        }
        let text = String(decoding: try cache.encoded(), as: UTF8.self)
        let names = OutcomeCacheTests.keys.map { OutcomeCacheTests.key($0).hexadecimal }.sorted()
        let places = names.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(places.count == names.count)
        #expect(places == places.sorted(), "the answers are not in order of their names")
    }

    /// Where a cache lives is the user's cache directory, keyed by the package it is
    /// about - so two packages do not share answers and neither writes into a repository.
    @Test("lives outside the package it is about")
    func livesElsewhere() throws {
        let one = OutcomeCache.location(for: URL(filePath: "/work/alpha"))
        let other = OutcomeCache.location(for: URL(filePath: "/work/beta"))
        #expect(one != other)
        #expect(!one.path.hasPrefix("/work/alpha"))
        #expect(one.lastPathComponent.hasSuffix(".json"))
    }

    /// The same package is the same place, however it was spelled on the command line.
    @Test("finds the same place for the same package")
    func sameePackageSamePlace() {
        #expect(
            OutcomeCache.location(for: URL(filePath: "/work/alpha"))
                == OutcomeCache.location(for: URL(filePath: "/work/alpha/"))
        )
    }
}
