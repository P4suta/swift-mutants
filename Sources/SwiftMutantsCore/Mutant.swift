// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// One mutant: an edit that could be made, and what it would do to the source.
///
/// The identity is derived rather than stored separately, so a mutant cannot be built
/// carrying an identity that is not its own — which would be a mutant that adopted somebody
/// else's cached verdict.
///
/// Two of the initialiser's arguments are not kept. The enclosing declaration and the
/// file's digest are what the identity is made of, and the identity is made here; keeping
/// a second copy of an input nothing reads back would be a second place for it to be
/// wrong.
public struct Mutant: Sendable, Hashable {

    /// Where the mutated file is, relative to the workspace root.
    public let path: WorkspaceRelativePath

    /// Which rule produced it, at which version.
    public let rule: RuleIdentifier

    /// The bytes the edit replaces.
    public let span: SourceSpan

    /// The source text at ``span``, as the file has it.
    public let original: String

    /// The text the mutant puts there instead.
    public let replacement: String

    /// What this mutant is called. Derived from everything above.
    public let identity: MutantIdentity

    /// Creates a mutant and computes its identity.
    public init(
        path: WorkspaceRelativePath,
        enclosingDeclaration: String,
        rule: RuleIdentifier,
        span: SourceSpan,
        sourceDigest: Digest,
        original: String,
        replacement: String
    ) {
        self.path = path
        self.rule = rule
        self.span = span
        self.original = original
        self.replacement = replacement
        identity = MutantIdentity(
            MutantIdentity.Inputs(
                path: path,
                enclosingDeclaration: enclosingDeclaration,
                rule: rule,
                span: span,
                sourceDigest: sourceDigest,
                originalBytes: Digest.of(original),
                replacementBytes: Digest.of(replacement)
            )
        )
    }
}
