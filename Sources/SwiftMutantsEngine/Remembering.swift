// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCache
import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsInstrument

/// What a previous run already answered, and what this one has to ask.
///
/// A mutation run's whole cost is the mutants it executes, so the largest saving available
/// is not executing the ones whose answer cannot have changed. Whether it can have changed
/// is not a guess: an answer rests on the mutant, which is content-addressed, and on the
/// files the tests that reach it were seen to execute, which the probe observed.
///
/// It fails closed at every step. A mutant whose dependencies are not fully known is asked
/// again; a cache file that cannot be read is no cache; an answer about the machine rather
/// than about the program was never stored. The cost of asking again is one process, and
/// the cost of being wrong is a score somebody believes.
struct Remembering: Sendable {

    /// The key each mutant's answer is filed under, by index.
    private let keys: [UInt32: Digest]

    /// What was known before this run started.
    private let known: OutcomeCache

    /// Nothing remembered, and nothing to remember.
    static var nothing: Self { Self(keys: [:], known: OutcomeCache()) }

    /// Works out what may be remembered about each mutant of this run.
    ///
    /// - Parameters:
    ///   - catalogue: which file each mutant is in, and what each one is called.
    ///   - coverage: what the probe found, or nothing if there was no probe - in which case
    ///     nothing is remembered, because a dependency set nobody observed is not one.
    ///   - digests: a digest of every file the package has.
    ///   - cache: what previous runs wrote down.
    ///   - expected: identities a `[[mutation.expect]]` row asked to be checked, which get
    ///     no key at all - so nothing is looked up for them and nothing is written down
    ///     about them. An expectation answered from last week's cache is a claim nobody
    ///     tested, which is the one thing an expectation must not be.
    /// - Returns: what may be remembered about this run's mutants.
    static func of(
        _ catalogue: MutantCatalogue,
        coverage: Coverage?,
        digests: [WorkspaceRelativePath: Digest],
        cache: OutcomeCache,
        expecting expected: Set<String>
    ) -> Self {
        let files = catalogue.files
        let identities = catalogue.identities
        guard let coverage else { return .nothing }
        let dependencies = Dependencies.map(
            reach: coverage.reach,
            covering: coverage.byMutantForCaching,
            files: files,
            digests: digests
        )
        var keys: [UInt32: Digest] = [:]
        for (index, resting) in dependencies {
            guard let identity = identities[index] else { continue }
            guard !expected.contains(identity.rendered) else { continue }
            keys[index] =
                CacheKey(
                    mutant: identity, dependencies: resting, toolVersion: ToolIdentity.current
                ).digest
        }
        return Self(keys: keys, known: cache)
    }

    /// The key one mutant's answer is filed under, when it has one.
    func key(for index: UInt32) -> Digest? { keys[index] }

    /// The answer to this mutant that needs no process, if there is one.
    func answer(for index: UInt32) -> CachedAnswer? {
        guard let key = keys[index] else { return nil }
        return known.answer(for: key)
    }

    /// The cache this run leaves behind: what was known, plus what was learned.
    ///
    /// A mutant whose key could not be worked out contributes nothing rather than being
    /// filed under a partial key, which would be an answer waiting to be given to the
    /// wrong question.
    func recording(_ results: [MutantResult], by index: [MutantIdentity: UInt32]) -> OutcomeCache {
        results.reduce(known) { cache, result in
            guard let position = index[result.identity], let key = keys[position] else {
                return cache
            }
            return cache.recording(
                key,
                CachedAnswer(
                    outcome: result.verdict.outcome,
                    killedBy: result.verdict.killedBy,
                    testsStarted: result.verdict.testsStarted,
                    durationMilliseconds: result.verdict.durationMilliseconds
                )
            )
        }
    }
}
