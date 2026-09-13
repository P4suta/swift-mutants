// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// A place a mutant could go.
///
/// Two spans, because an edit and the guard that switches it on are different things. The
/// edit is the bytes that change - one operator, one literal. The guard wraps the smallest
/// expression that contains it, because that is what a ternary can be put around without
/// disturbing the statement it sits in.
public struct Candidate: Sendable, Hashable {

    /// Which rule produced it, at which version.
    public let rule: RuleIdentifier

    /// The bytes the edit replaces.
    public let span: SourceSpan

    /// What the file has there now.
    public let original: String

    /// What the mutant puts there instead.
    public let replacement: String

    /// The expression a guard would wrap. Always contains ``span``.
    public let guardSpan: SourceSpan

    /// A name for the declaration the edit sits inside, or `""` when there is none.
    ///
    /// Syntactic - `Header.parse` - rather than a mangled symbol. It goes into the mutant's
    /// identity so that an edit is not renamed by an unrelated change higher up the file,
    /// and into the report so that a reader knows where to look.
    public let enclosingDeclaration: String
}

/// Somewhere this tool decided not to put a mutant, and why.
///
/// Skips are data. The walk keeps walking inside a skipped region and counts the candidates
/// it would have produced, so that "why is this smaller than I expected" is a question the
/// report can answer rather than one somebody has to read the source to guess at.
public struct Skip: Sendable, Hashable {

    /// Why the region was passed over.
    public let reason: SkipReason

    /// The region.
    public let span: SourceSpan

    /// How many candidates this reason hid.
    public let candidatesHidden: Int
}

/// The named reasons a region is passed over.
///
/// Named rather than anonymous, because a count of skips is not an answer. The strings are
/// what `list --explain` prints and what the catalogue JSON carries.
public enum SkipReason: String, Sendable, Hashable, CaseIterable {

    /// Code no test could reasonably assert on: logging, assertions, metrics.
    ///
    /// The highest-yield rule there is. Google measured suppression of this kind taking the
    /// median mutant count for one change from 820 to 7, and the productivity of what
    /// remained from 15% to 89%.
    case arid

    /// Inside a macro's arguments.
    ///
    /// A macro's expansion is code nobody wrote, and a guard spliced into one expands into
    /// types the surrounding code cannot hold - with the compiler's complaint hidden in a
    /// macro buffer, which is how it reaches a reader as an unrelated error.
    case macroExpansion = "macro-expansion"

    /// A comment asked for it.
    case disabledByComment = "disabled-by-comment"

    /// An operator this tool has no meaning for.
    case userDefinedOperator = "user-defined-operator"

    /// A configuration pattern removed the file.
    case excluded
}

/// What one file yielded.
public struct FileDiscovery: Sendable, Hashable {

    /// Where the file is, relative to the workspace root.
    public let path: WorkspaceRelativePath

    /// A digest of the file as it was read.
    public let sourceDigest: Digest

    /// What could be mutated, in the order it appears in the file.
    public let candidates: [Candidate]

    /// What was passed over, and why.
    public let skips: [Skip]

    /// Suppression comments naming something this build has never heard of.
    ///
    /// Reported rather than ignored. A comment that silences nothing is worse than no
    /// comment: somebody wrote it, believed a mutant was dealt with, and it is still there.
    public let unknownSuppressions: [UnknownSuppression]

    /// Records what was found in one file.
    public init(
        path: WorkspaceRelativePath,
        sourceDigest: Digest,
        candidates: [Candidate],
        skips: [Skip],
        unknownSuppressions: [UnknownSuppression] = []
    ) {
        self.path = path
        self.sourceDigest = sourceDigest
        self.candidates = candidates
        self.skips = skips
        self.unknownSuppressions = unknownSuppressions
    }

    /// The same discovery with only the candidates that pass `isKept`.
    ///
    /// Validation is a loop: instrument everything, ask the compiler, drop what it
    /// refused, ask again. Narrowing the discovery rather than the instrumented output is
    /// what keeps the second pass identical to a first pass over a smaller catalogue -
    /// same numbering rules, same guard shapes, same identities for the survivors.
    ///
    /// The digest does not change, because the file did not.
    public func keeping(_ isKept: (Candidate) -> Bool) -> Self {
        Self(
            path: path,
            sourceDigest: sourceDigest,
            candidates: candidates.filter(isKept),
            skips: skips,
            unknownSuppressions: unknownSuppressions
        )
    }
}

/// A suppression comment naming a family this build does not have.
public struct UnknownSuppression: Sendable, Hashable {

    /// The line the comment is on, counting from one.
    public let line: Int

    /// What it named.
    public let name: String

    /// Records a comment that silences nothing.
    public init(line: Int, name: String) {
        self.line = line
        self.name = name
    }
}
