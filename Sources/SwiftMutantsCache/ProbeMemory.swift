// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import SwiftMutantsCore

/// What each test was seen to run, from a previous run.
///
/// After the outcome cache, the last thing a warm run still pays for is asking every test
/// what it reaches - one process per test, and a process launch costs about what a handful
/// of tests cost. On this package that is several hundred launches to rediscover something
/// that did not change.
///
/// What a test runs changes only when the code it runs changes, which is the question the
/// outcome cache already answers, answered the same way: the files it was seen to evaluate a
/// guard in, plus everything nothing can be observed about - every test file, and every file
/// with no mutants in it.
///
/// One thing is remembered differently. A mutant is kept by its identity rather than by the
/// number its guard spells, because the numbering shifts when any file gains a mutant and an
/// identity is the same mutant whatever else moved.
public struct ProbeMemory: Codable, Sendable, Hashable {

    /// The version of the file this reads and writes.
    static let fileVersion = 1

    /// What one test was seen to do.
    struct Entry: Codable, Sendable, Hashable {
        /// The files it evaluated a guard in, with the digest each had at the time.
        let ran: [String: Digest]
        /// The mutants it reached, by identity.
        ///
        /// Held as digests rather than as text, so that a hand-edited file names a mutant
        /// that could exist or names nothing at all - `Digest` refuses anything that is not
        /// sixty-four lowercase hexadecimal characters.
        let reaching: [Digest]
    }

    private let version: Int

    /// Which build of this tool saw it. A different one may instrument differently.
    private let toolVersion: String

    /// The files something could be observed about, as they were.
    ///
    /// Kept so that a package which gained or lost a file with mutants in it is not read
    /// against a memory of a differently-shaped package.
    private let observable: [String]

    /// A digest of every other file, together.
    ///
    /// One value rather than a list, because any change to any of them invalidates
    /// everything: a test might run one and nobody would see.
    private let unobservable: String

    private var byTest: [String: Entry]

    /// Starts a memory of a package whose observable files are `observable`.
    public init(
        toolVersion: String,
        observable: [WorkspaceRelativePath],
        digests: [WorkspaceRelativePath: Digest]
    ) {
        self.version = Self.fileVersion
        self.toolVersion = toolVersion
        self.observable = observable.map(\.rendered).sorted()
        self.unobservable = Self.remainder(observable: Set(observable), digests: digests)
        self.byTest = [:]
    }

    /// Whether anything is remembered.
    public var isEmpty: Bool { byTest.isEmpty }

    /// How many tests are remembered.
    public var count: Int { byTest.count }

    /// The mutants a test was seen to reach, if everything that answer rests on is unchanged.
    ///
    /// Nothing when the test was never seen, when a file it ran has changed, when anything
    /// nothing can be observed about has changed, or when the package has a different set of
    /// files to observe. Each is a reason the answer might be different now, and the cost of
    /// asking again is one process.
    public func reach(
        of test: String,
        observable current: [WorkspaceRelativePath],
        digests: [WorkspaceRelativePath: Digest]
    ) -> [Digest]? {
        guard let entry = byTest[test],
            current.map(\.rendered).sorted() == observable,
            Self.remainder(observable: Set(current), digests: digests) == unobservable
        else {
            return nil
        }
        for (path, digest) in entry.ran {
            guard let named = WorkspaceRelativePath(path), digests[named] == digest else {
                return nil
            }
        }
        return entry.reaching
    }

    /// The same memory, with one more test's findings in it.
    ///
    /// The digest of each file is taken now rather than looked up later, so that an entry
    /// carries both halves of what it rests on and nothing has to reconstruct the pairing.
    public func recording(
        _ test: String,
        ran files: [WorkspaceRelativePath],
        reaching mutants: [Digest],
        digests: [WorkspaceRelativePath: Digest]
    ) -> Self {
        var kept = self
        var ran: [String: Digest] = [:]
        for file in files where digests[file] != nil { ran[file.rendered] = digests[file] }
        kept.byTest[test] = Entry(
            ran: ran, reaching: mutants.sorted { $0.hexadecimal < $1.hexadecimal })
        return kept
    }

    /// A digest of every file nothing can be observed in, together.
    private static func remainder(
        observable: Set<WorkspaceRelativePath>, digests: [WorkspaceRelativePath: Digest]
    ) -> String {
        var builder = DigestBuilder().adding("swift-mutants-unobservable-v1")
        for path in digests.keys.sorted(by: { $0.rendered < $1.rendered })
        where !observable.contains(path) {
            builder = builder.adding(path.rendered)
            if let digest = digests[path] { builder = builder.adding(digest) }
        }
        return builder.finalize().hexadecimal
    }
}

extension ProbeMemory {

    /// Where a package's memory lives.
    public static func location(for package: URL) -> URL {
        let root =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = DigestBuilder()
            .adding("swift-mutants-package")
            .adding(package.standardizedFileURL.path)
            .finalize()
        return
            root
            .appending(path: "swift-mutants")
            .appending(path: "probe-\(name.hexadecimal).json")
    }

    /// The memory kept there, or an empty one.
    ///
    /// Empty for a file that is not there, one this build cannot read, and one another
    /// build wrote: a different build of this tool may instrument differently, so what a
    /// test was seen to run under one is not evidence about another.
    public static func read(from file: URL, asOf toolVersion: String) -> Self {
        guard let data = try? Data(contentsOf: file),
            let stored = try? JSONDecoder().decode(Self.self, from: data)
        else {
            return Self(toolVersion: toolVersion, observable: [], digests: [:])
        }
        return Self.read(from: stored, asOf: toolVersion)
    }

    /// The same memory, or an empty one when it was not written by this build.
    public static func read(from stored: Self, asOf toolVersion: String) -> Self {
        guard stored.version == Self.fileVersion, stored.toolVersion == toolVersion else {
            return Self(toolVersion: toolVersion, observable: [], digests: [:])
        }
        return stored
    }

    /// The memory as bytes, the same bytes every time.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Writes it down, making the directory it lives in if it is not there.
    public func write(to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: file)
    }
}
