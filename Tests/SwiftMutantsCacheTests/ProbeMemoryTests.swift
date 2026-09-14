// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsCache

/// Remembering what a test was seen to run.
///
/// After the outcome cache, the last thing a warm run still pays for is asking every test
/// what it reaches - one process per test, and a process launch costs about what a handful
/// of tests cost. On this package that is several hundred launches to rediscover something
/// that did not change.
///
/// What a test runs changes only when the code it runs changes, which is the same question
/// the outcome cache answers and is answered the same way: the files it was seen to
/// evaluate a guard in, plus everything nothing can be observed about. The difference is
/// what is remembered - mutants by their identities rather than by their numbers, because
/// the numbering shifts when any file gains a mutant and an identity does not.
@Suite("Remembering what a test runs")
struct ProbeMemoryTests {

    static func path(_ name: String) -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/\(name).swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static let one = Self.path("A")
    static let two = Self.path("B")
    static let bare = Self.path("C")

    static func digests(
        _ overrides: [WorkspaceRelativePath: String] = [:]
    )
        -> [WorkspaceRelativePath: Digest]
    {
        var found: [WorkspaceRelativePath: Digest] = [
            one: Digest.of("A"), two: Digest.of("B"), bare: Digest.of("C"),
        ]
        for (path, contents) in overrides { found[path] = Digest.of(contents) }
        return found
    }

    /// One test that runs `A`, and one that runs `B`.
    static func remembered(
        digests: [WorkspaceRelativePath: Digest]? = nil, version: String = "1.0.0"
    ) -> ProbeMemory {
        ProbeMemory(
            toolVersion: version, observable: [one, two], digests: digests ?? Self.digests()
        )
        .recording(
            "t", ran: [one], reaching: [Digest.of("m1")], digests: digests ?? Self.digests()
        )
        .recording(
            "u", ran: [two], reaching: [Digest.of("m2")], digests: digests ?? Self.digests()
        )
    }

    @Test("gives back what a test was seen to run")
    func remembers() {
        let memory = Self.remembered()
        #expect(
            memory.reach(of: "t", observable: [Self.one, Self.two], digests: Self.digests()) == [
                Digest.of("m1")
            ])
    }

    @Test("has nothing to say about a test it never saw")
    func knowsNothingElse() {
        #expect(
            Self.remembered().reach(
                of: "v", observable: [Self.one, Self.two], digests: Self.digests()) == nil)
    }

    /// The whole point: a change somewhere this test does not go leaves its answer standing.
    @Test("keeps an answer when a file the test does not run changed")
    func unrelatedChangesKeepIt() {
        let changed = Self.digests([Self.two: "B, edited"])
        #expect(
            Self.remembered().reach(of: "t", observable: [Self.one, Self.two], digests: changed)
                == [Digest.of("m1")])
    }

    /// And the direction that matters: a change where the test does go throws it away.
    @Test("throws an answer away when a file the test runs changed")
    func relatedChangesLoseIt() {
        let changed = Self.digests([Self.one: "A, edited"])
        #expect(
            Self.remembered().reach(of: "t", observable: [Self.one, Self.two], digests: changed)
                == nil)
    }

    /// A file nothing can be observed in - a test file, or one with no mutants - belongs to
    /// every answer, because a test might run it and nobody would see.
    @Test("throws every answer away when a file nothing can see into changed")
    func unobservableChangesLoseEverything() {
        let changed = Self.digests([Self.bare: "C, edited"])
        #expect(
            Self.remembered().reach(of: "t", observable: [Self.one, Self.two], digests: changed)
                == nil)
        #expect(
            Self.remembered().reach(of: "u", observable: [Self.one, Self.two], digests: changed)
                == nil)
    }

    /// A file that appeared or vanished changes what can be observed at all.
    @Test("throws every answer away when the package gained a file")
    func aNewFileLosesEverything() {
        var grown = Self.digests()
        grown[Self.path("D")] = Digest.of("D")
        #expect(
            Self.remembered().reach(of: "t", observable: [Self.one, Self.two], digests: grown)
                == nil)
    }

    /// A different build of this tool may instrument differently, so what a test was seen
    /// to run under one is not evidence about another.
    @Test("throws every answer away when the tool changed")
    func aNewToolLosesEverything() {
        let memory = Self.remembered(version: "1.0.0")
        let read = ProbeMemory.read(from: memory, asOf: "1.0.1")
        #expect(
            read.reach(of: "t", observable: [Self.one, Self.two], digests: Self.digests()) == nil)
    }

    /// Mutants are remembered by name rather than by number. The numbering shifts when any
    /// file gains a mutant; an identity is the same mutant whatever else moved.
    @Test("remembers mutants by name, not by where they were in the queue")
    func remembersByName() throws {
        let memory = Self.remembered()
        let reach = try #require(
            memory.reach(of: "t", observable: [Self.one, Self.two], digests: Self.digests()))
        #expect(reach == [Digest.of("m1")])
    }
}

/// Keeping it between runs.
@Suite("A probe memory on disk")
struct ProbeMemoryStorageTests {

    @Test("comes back the way it went in")
    func roundTrips() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-probe-\(UUID().uuidString)/memory.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let memory = ProbeMemoryTests.remembered()
        try memory.write(to: file)

        let again = ProbeMemory.read(from: file, asOf: "1.0.0")
        #expect(
            again.reach(
                of: "t",
                observable: [ProbeMemoryTests.one, ProbeMemoryTests.two],
                digests: ProbeMemoryTests.digests()
            ) == [Digest.of("m1")])
    }

    /// Nothing there is the first run, and a file it cannot trust is the same answer.
    @Test("has nothing to say about what it cannot read", arguments: ["", "{", "[]"])
    func nothingUsable(_ contents: String) throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-probe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(contents.utf8).write(to: file)

        #expect(ProbeMemory.read(from: file, asOf: "1.0.0").isEmpty)
    }

    @Test("has nothing to say before the first run")
    func nothingYet() {
        #expect(
            ProbeMemory.read(
                from: URL(filePath: "/swift-mutants-nowhere/memory.json"), asOf: "1.0.0"
            ).isEmpty)
    }

    @Test("keeps a package's memory apart from another's")
    func livesApart() {
        #expect(
            ProbeMemory.location(for: URL(filePath: "/work/alpha"))
                != ProbeMemory.location(for: URL(filePath: "/work/beta")))
    }
}

/// Answering many tests without re-deriving the same thing for each one.
///
/// What a memory checks before it answers is the same for every test in a run: the package
/// has the same shape and the same files it cannot see into. Working that out once per test
/// is `Θ(tests × files log files)` - unnoticeable here and not on a package with thousands
/// of each.
@Suite("Answering many tests")
struct ProbeReaderTests {

    static func reader(_ digests: [WorkspaceRelativePath: Digest]? = nil) -> ProbeMemory.Reader {
        ProbeMemoryTests.remembered()
            .reader(
                observable: [ProbeMemoryTests.one, ProbeMemoryTests.two],
                digests: digests ?? ProbeMemoryTests.digests()
            )
    }

    @Test("gives the same answers as asking one at a time")
    func agreesWithTheSlowWay() {
        let reader = Self.reader()
        #expect(reader.reach(of: "t") == [Digest.of("m1")])
        #expect(reader.reach(of: "u") == [Digest.of("m2")])
        #expect(reader.reach(of: "v") == nil)
    }

    @Test("throws an answer away when a file the test runs changed")
    func relatedChangesLoseIt() {
        let reader = Self.reader(ProbeMemoryTests.digests([ProbeMemoryTests.one: "A, edited"]))
        #expect(reader.reach(of: "t") == nil)
        #expect(reader.reach(of: "u") == [Digest.of("m2")])
    }

    /// A package that changed shape, or changed anywhere nothing can see into, answers
    /// nothing at all - and answers it without looking at a single test.
    @Test("answers nothing at all when the package itself changed")
    func wholesaleChangesLoseEverything() {
        let changed = Self.reader(ProbeMemoryTests.digests([ProbeMemoryTests.bare: "C, edited"]))
        #expect(changed.reach(of: "t") == nil)
        #expect(changed.reach(of: "u") == nil)

        var grown = ProbeMemoryTests.digests()
        grown[ProbeMemoryTests.path("D")] = Digest.of("D")
        #expect(Self.reader(grown).reach(of: "t") == nil)
    }
}
