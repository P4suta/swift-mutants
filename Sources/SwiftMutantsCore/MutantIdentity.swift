// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// What a mutant is called.
///
/// The identity decides which cached outcome applies to a mutant, whether an expectation
/// somebody wrote into their configuration is still about *this* mutant, and which shard
/// it lands in when a run is spread across machines. It therefore has to depend on
/// everything that makes the mutant what it is, and on nothing else.
///
/// "Nothing else" is the harder half. It rules out absolute paths, snapshot locations, the
/// order in which discovery happened to walk the tree, the machine, and the clock — every
/// one of which would make an identity change for a reason that is not about the program.
/// ``WorkspaceRelativePath`` refuses to hold a location at all, and nothing else in the
/// input is machine-dependent.
///
/// Everything downstream falls out of this one value: the outcome cache keys on it,
/// `--shard K/N` assigns from it, `report merge` matches on it, SARIF uses it as a
/// `partialFingerprint`, and `swift-mutants explain` resolves a prefix of it.
public struct MutantIdentity: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// Everything a mutant's identity is computed from.
    ///
    /// A struct rather than a long parameter list, so that a test can vary one field at a
    /// time and assert that each one reaches the digest. A field that never reaches it is
    /// how two different mutants come to share an identity.
    public struct Inputs: Sendable, Hashable {

        /// Where the mutated file is, relative to the workspace root.
        public let path: WorkspaceRelativePath

        /// A stable name for the declaration the edit sits inside, or `""` when discovery
        /// could not determine one.
        ///
        /// Including it is what stops an edit from being renamed by an unrelated change
        /// higher up the file: the byte span moves, but a reader looking for "the mutant
        /// in `parse(_:)`" is looking for something the identity still records. Empty is a
        /// distinct value rather than an absent one, because ``DigestBuilder`` length-
        /// prefixes every field.
        public let enclosingDeclaration: String

        /// Which rule produced the mutant, at which version.
        public let rule: RuleIdentifier

        /// The bytes the edit replaces.
        public let span: SourceSpan

        /// The digest of the whole file as it was read.
        ///
        /// This is what makes an identity specific to the program it was computed about. An
        /// identity that survived an edit to the file would let a run adopt a verdict that
        /// was reached about different code.
        public let sourceDigest: Digest

        /// The digest of the original bytes at ``span``.
        public let originalBytes: Digest

        /// The digest of the bytes the mutant puts there instead.
        public let replacementBytes: Digest

        /// Creates the inputs for one mutant's identity.
        public init(
            path: WorkspaceRelativePath,
            enclosingDeclaration: String,
            rule: RuleIdentifier,
            span: SourceSpan,
            sourceDigest: Digest,
            originalBytes: Digest,
            replacementBytes: Digest
        ) {
            self.path = path
            self.enclosingDeclaration = enclosingDeclaration
            self.rule = rule
            self.span = span
            self.sourceDigest = sourceDigest
            self.originalBytes = originalBytes
            self.replacementBytes = replacementBytes
        }
    }

    /// The digest that names the mutant.
    public let digest: Digest

    /// The full identity, as sixty-four hexadecimal characters.
    public var rendered: String { digest.hexadecimal }

    /// The prefix the CLI displays, checked for collisions against the catalogue it came
    /// from. JSON always carries ``rendered``.
    public var shortForm: String { digest.shortForm }

    /// The full identity, never abbreviated.
    public var description: String { rendered }

    /// Computes the identity of a mutant.
    ///
    /// The scheme version leads the field sequence so that a future change to what an
    /// identity is made of moves every identity at once, rather than leaving old and new
    /// values indistinguishable in one cache directory.
    public init(_ inputs: Inputs) {
        digest =
            DigestBuilder()
            .adding(SwiftMutantsCore.identitySchemeVersion)
            .adding(inputs.path.rendered)
            .adding(inputs.enclosingDeclaration)
            .adding(inputs.rule.rendered)
            .adding(inputs.span.start)
            .adding(inputs.span.end)
            .adding(inputs.sourceDigest)
            .adding(inputs.originalBytes)
            .adding(inputs.replacementBytes)
            .finalize()
    }

    /// Orders by digest, so a catalogue sorts identically on every machine.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.digest < rhs.digest }
}

extension MutantIdentity: Codable {
    /// Encodes as the full identity. Never the short form: a document is read back by
    /// `report merge` and by the cache, and a prefix is a name that could belong to more
    /// than one mutant.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(digest)
    }

    /// Decodes a full identity.
    public init(from decoder: any Decoder) throws {
        digest = try decoder.singleValueContainer().decode(Digest.self)
    }
}
