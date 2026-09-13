// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Everything a run found, in one order, under one digest.
///
/// The order is fixed here rather than left to however discovery walked the tree, because
/// two machines reading the same code have to produce the same catalogue: `--shard K/N`
/// assigns from it, `report merge` checks that shards describe one run by comparing it, and
/// a reader diffing two reports should see only what changed in the program.
public struct Catalog: Sendable {

    /// Why a set of mutants could not be a catalogue.
    public enum Failure: Error, Sendable, Equatable {

        /// Two entries carried the same identity.
        ///
        /// Refused rather than de-duplicated: two mutants with one name means one of them
        /// would adopt the other's cached verdict, and which one it was depends on the
        /// order they arrived in.
        case duplicateIdentity(MutantIdentity)
    }

    /// What resolving a short identifier found.
    public enum Resolution: Sendable, Equatable {

        /// Nothing in the catalogue starts with that prefix.
        case notFound

        /// Exactly one mutant does.
        case one(Mutant)

        /// Several do, and they are named rather than chosen between.
        ///
        /// "Probably the one you meant" is not an answer a tool should give about an
        /// identifier.
        case ambiguous([MutantIdentity])
    }

    /// The mutants, ordered by path, then by span, then by rule.
    public let mutants: [Mutant]

    /// A digest over the identities, in order.
    ///
    /// It goes into the outcome cache's key, so it has to move whenever the set of mutants
    /// moves and stay still otherwise. Entries are *filed* under a key rather than
    /// validated against one, so a catalogue that changed would make old entries
    /// unreachable rather than wrong.
    public let digest: Digest

    private let byIdentity: [MutantIdentity: Mutant]

    /// Builds a catalogue, or refuses a set of mutants that cannot be one.
    public init(_ mutants: some Sequence<Mutant>) throws(Failure) {
        let ordered = mutants.sorted { left, right in
            if left.path != right.path { return left.path < right.path }
            if left.span != right.span { return left.span < right.span }
            if left.rule != right.rule { return left.rule < right.rule }
            return left.identity < right.identity
        }

        var index: [MutantIdentity: Mutant] = [:]
        index.reserveCapacity(ordered.count)
        var builder = DigestBuilder().adding("swift-mutants/catalog")
        for mutant in ordered {
            guard index.updateValue(mutant, forKey: mutant.identity) == nil else {
                throw .duplicateIdentity(mutant.identity)
            }
            builder = builder.adding(mutant.identity.digest)
        }

        self.mutants = ordered
        byIdentity = index
        digest = builder.finalize()
    }

    /// The mutant with that identity, if the catalogue holds it.
    public subscript(identity: MutantIdentity) -> Mutant? { byIdentity[identity] }

    /// Finds the mutant whose identity starts with `prefix`.
    ///
    /// A prefix is what a person types and what `--mutant` accepts. Several matches are
    /// reported as several rather than resolved by picking one, because a tool that guessed
    /// would run a mutant the user did not ask for and report it under a name they did.
    public func resolve(prefix: String) -> Resolution {
        let matches = mutants.filter { $0.identity.rendered.hasPrefix(prefix) }
        guard let only = matches.first else { return .notFound }
        return matches.count == 1 ? .one(only) : .ambiguous(matches.map(\.identity))
    }
}
