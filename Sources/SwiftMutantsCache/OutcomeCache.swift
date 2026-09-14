// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import SwiftMutantsCore

/// What a previous run established about one mutant.
///
/// Deliberately small. Everything else about a mutant - where it is, what it changed, which
/// rule made it - is in the catalogue, and a cache that carried its own copy would be a
/// second place for that to be wrong.
public struct CachedAnswer: Codable, Sendable, Hashable {

    /// What became of it.
    public let outcome: Outcome

    /// The tests that failed with it awake, in the order their failures arrived.
    public let killedBy: [String]

    /// How many tests it was offered and began.
    public let testsStarted: Int

    /// How long the run that decided it took.
    public let durationMilliseconds: Int

    /// Records one answer.
    public init(
        outcome: Outcome, killedBy: [String], testsStarted: Int, durationMilliseconds: Int
    ) {
        self.outcome = outcome
        self.killedBy = killedBy
        self.testsStarted = testsStarted
        self.durationMilliseconds = durationMilliseconds
    }

    /// Whether this is a fact about the program rather than about the machine.
    ///
    /// Only a kill, a survival and a confirmed timeout are. A mutant that errored, that ran
    /// out of time once on a busy laptop, that somebody interrupted, or that the compiler
    /// refused is a statement about the afternoon it happened in - and a cache that kept
    /// those would make a bad afternoon permanent.
    public var isWorthRemembering: Bool {
        switch outcome {
        case .killed, .survived, .timedOut: true
        case .inconclusive, .errored, .notRun, .rejected, .equivalent: false
        }
    }
}

/// Answers a previous run established, filed under what they rest on.
///
/// A value rather than a handle: it is read once at the start of a run and written once at
/// the end, and nothing in between has to think about a file. That also makes it something
/// a test can hold.
public struct OutcomeCache: Sendable, Hashable {

    /// The version of the file this reads and writes.
    ///
    /// A file from another version is not upgraded, it is ignored - the cost of being wrong
    /// about a cache is a wrong score, and the cost of being right the slow way is one run.
    static let fileVersion = 1

    private var answers: [String: CachedAnswer]

    /// Starts with nothing remembered.
    public init() { self.answers = [:] }

    private init(answers: [String: CachedAnswer]) { self.answers = answers }

    /// How many answers are held.
    public var count: Int { answers.count }

    /// Whether anything is held.
    public var isEmpty: Bool { answers.isEmpty }

    /// What is known about this question, if anything.
    public func answer(for key: Digest) -> CachedAnswer? { answers[key.hexadecimal] }

    /// The same cache, with one more answer in it.
    ///
    /// An answer that is about the machine rather than about the program is dropped rather
    /// than refused: the caller has a result either way, and there is nothing it could do
    /// differently.
    public func recording(_ key: Digest, _ answer: CachedAnswer) -> Self {
        guard answer.isWorthRemembering else { return self }
        var kept = answers
        kept[key.hexadecimal] = answer
        return Self(answers: kept)
    }
}

extension OutcomeCache {

    /// The file a package's answers live in.
    ///
    /// Outside the package, because a run must not write into somebody's repository, and
    /// keyed by where the package is so that two of them do not share answers. The name is
    /// a digest rather than a path so that it is a filename on every platform and says
    /// nothing about the directories it came from.
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
            .appending(path: "outcomes-\(name.hexadecimal).json")
    }

    /// What a cache file holds.
    private struct Stored: Codable {
        let version: Int
        let answers: [String: CachedAnswer]
    }

    /// Reads a cache, or starts an empty one.
    ///
    /// Nothing there is the first run, not an error. A file it cannot trust is also an
    /// empty cache: a few answers out of a half-written file is exactly the shape of "some
    /// mutants were quietly skipped", which is the one failure this tool must not have.
    /// Measuring again is cheap and being wrong is not.
    public static func read(from file: URL) -> Self {
        guard let data = try? Data(contentsOf: file),
            let stored = try? JSONDecoder().decode(Stored.self, from: data),
            stored.version == Self.fileVersion
        else {
            return Self()
        }
        return Self(answers: stored.answers)
    }

    /// The cache as bytes, the same bytes every time.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try encoder.encode(Stored(version: Self.fileVersion, answers: answers))
    }

    /// Writes the cache, making the directory it lives in if it is not there.
    public func write(to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: file)
    }
}
