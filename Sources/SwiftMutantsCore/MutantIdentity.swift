// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A digest binding a mutation to its original source, path, rule, and edit.
/// Absolute checkout paths and discovery order do not participate in the identity.
public struct MutantIdentity: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// Everything a mutant's identity is computed from.
    ///
    /// A struct rather than a long parameter list, so that a test can vary one field at a time and assert that each one reaches the digest.
    /// A field that never reaches it is how two different mutants come to share an identity.
    public struct Inputs: Sendable, Hashable {

        /// Where the mutated file is, relative to the workspace root.
        public let path: WorkspaceRelativePath

        /// The enclosing declaration's syntactic name, or an empty string when unknown.
        /// Source digests and byte spans still bind the identity to the original file.
        public let enclosingDeclaration: String

        /// Which rule produced the mutant, at which version.
        public let rule: RuleIdentifier

        /// The bytes the edit replaces.
        public let span: SourceSpan

        /// The digest of the whole file as it was read.
        ///
        /// This is what makes an identity specific to the program it was computed about.
        /// An identity that survived an edit to the file would let a run adopt a verdict that was reached about different code.
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

    /// A display prefix without collision resolution.
    public var shortForm: String { digest.shortForm }

    /// The full identity, never abbreviated.
    public var description: String { rendered }

    /// Computes the identity of a mutant.
    ///
    /// The scheme version leads the field sequence so that a future change to what an identity is made of moves every identity at once, rather than leaving old and new values indistinguishable in one cache directory.
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
    /// Encodes the full identity without abbreviation.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(digest)
    }

    /// Decodes a full identity.
    public init(from decoder: any Decoder) throws {
        digest = try decoder.singleValueContainer().decode(Digest.self)
    }
}
