// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// What a mutant's answer depends on, and therefore what may be remembered.
///
/// A cache is only worth having if it is right, and the way an outcome cache is wrong is
/// silent: it answers `survived` for a mutant a test now catches, and the score goes up
/// while the tests got no better. So the key names everything that could change the answer
/// and nothing that could not - the first makes it unsound, the second makes it useless.
///
/// Three things can change the answer, and only three.
///
/// The mutant itself, which is already content-addressed: its identity covers the file's
/// digest, the span, the bytes on either side of the edit and the versioned rule that made
/// it. Edit the line and the mutant is a different mutant with a different name.
///
/// The behaviour of every file the tests that reach it execute. Nothing outside that set
/// can change what those tests conclude, and the set is not estimated: the probe records
/// which guards each test evaluated, every guard is in a file, so the files a test runs are
/// observed rather than guessed. That is what makes the cache worth having - a change to
/// one corner of a package invalidates the mutants whose tests go near it and leaves the
/// rest answered.
///
/// And the build of this tool, because a rule may come to mean something new or a verdict
/// may be decided differently, and an answer from one build is not evidence about another.
public struct CacheKey: Sendable, Hashable {

    /// Which mutant this is about.
    public let mutant: MutantIdentity

    /// The digest of every file the tests that reach it execute, sorted and deduplicated.
    ///
    /// Sorted because the order files were observed in is an accident of which worker
    /// finished first; deduplicated because two tests reaching one file report it twice.
    /// A key that depended on either would miss every time.
    public let dependencies: [Digest]

    /// Which build of this tool asked the question.
    public let toolVersion: String

    /// Records what one answer rests on.
    public init(mutant: MutantIdentity, dependencies: [Digest], toolVersion: String) {
        self.mutant = mutant
        self.dependencies = Array(Set(dependencies)).sorted { $0.hexadecimal < $1.hexadecimal }
        self.toolVersion = toolVersion
    }

    /// The name this answer is filed under.
    ///
    /// The strings are length-prefixed by the builder and the digests are all the same
    /// length, so no two different questions can be spelled the same way by moving a
    /// boundary between fields.
    public var digest: Digest {
        var builder = DigestBuilder()
            .adding("swift-mutants-cache-key-v1")
            .adding(toolVersion)
            .adding(mutant.digest)
        for dependency in dependencies { builder = builder.adding(dependency) }
        return builder.finalize()
    }
}
