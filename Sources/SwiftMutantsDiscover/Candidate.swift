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

    /// Records a region that was passed over.
    public init(reason: SkipReason, span: SourceSpan, candidatesHidden: Int) {
        self.reason = reason
        self.span = span
        self.candidatesHidden = candidatesHidden
    }
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

    /// Inside a default argument value.
    ///
    /// Kept as a name so that a catalogue written by an older build still decodes, and no
    /// longer produced by anything. The reason was true when it was written: Swift refuses a
    /// default argument value that references a `private` declaration, and the runtime this
    /// tool appends was private - so a guard there produced a complaint about the guard
    /// rather than about the mutant, which lands nowhere attribution can place it.
    ///
    /// The runtime stopped being private for an unrelated reason: Swift will not let an
    /// `@inlinable` function reference a private symbol either, so a package with inlinable
    /// inner loops had every mutant in them refused, and the fix was to make the runtime
    /// `@usableFromInline internal`. That fixed this as a side effect and nobody noticed.
    ///
    /// Measured directly on this toolchain before removing it: a guard in a default
    /// argument compiles in a public function, in an `@inlinable` one, in an initialiser,
    /// and under library evolution, which is the strictest of the four.
    case defaultArgument = "default-argument"

    /// Arithmetic where an operand is visibly not a number.
    ///
    /// `+` is the one arithmetic operator Swift also gives to strings and collections, and
    /// the only one it gives them - `["a"] - ["b"]` is not a program. So every arithmetic
    /// mutant at such a site is a rejection decided in advance: the compiler will refuse
    /// it, and the run pays a whole build of somebody's package to be told so.
    ///
    /// It costs more than the build. A guard whose branches differ by an operator adds an
    /// overload choice to the expression around it, and `+` over array literals is already
    /// the shape the Swift type checker struggles with. When it gives up, its complaint is
    /// about the expression rather than about any mutant in it, so nothing can be placed
    /// and the run halves its way through the catalogue instead - the most expensive path
    /// there is, entered for a mutant that could never have compiled.
    ///
    /// Only what syntax can see. `a + b` could be two integers, and the compiler remains
    /// the judge of everything this cannot decide.
    case nonNumericOperand = "non-numeric-operand"

    /// A boolean literal that is the whole condition of a loop.
    ///
    /// `while true` is not a decision the program makes. It is how Swift spells "loop", and
    /// flipping it does not perturb a predicate - it removes the loop, which a suite
    /// notices the way it would notice the body being deleted.
    ///
    /// It is usually not a program either. The compiler knows a `while true` with no
    /// `break` never falls out of the bottom, so a function may end with one and return
    /// nothing afterwards; `while false` falls out at once and leaves a path that returns
    /// nothing. The error for that is reported against the function's closing brace rather
    /// than against the literal, so it lands nowhere this tool put a mutant, and the run
    /// halves its way through the catalogue for a mutant that could never have compiled.
    case loopConditionLiteral = "loop-condition-literal"

    /// A configuration pattern removed the file.
    /// A project's own mutant whose anchor is not in the file any more.
    ///
    /// Code moved and the row stopped testing anything. Silence here is the failure this
    /// tool exists to prevent, one level up: somebody carries on believing they have
    /// coverage they do not, and believes it specifically about the code they just changed.
    case customAnchorNotFound = "custom-anchor-not-found"

    /// A project's own mutant whose anchor is in the file more than once.
    ///
    /// A different mistake from a moved one and it wants a different fix - a longer anchor
    /// rather than a re-anchoring - so it is said differently. Never "all the matches": a
    /// row that silently became forty mutants is a project measuring something it did not
    /// write down.
    case customAnchorNotUnique = "custom-anchor-not-unique"

    /// An expression holding a string whose newlines are part of what it means.
    ///
    /// The mutated copy of a site goes on one line, because the original copy beside it
    /// keeps every newline the file had and every line number in an instrumented file has
    /// to equal the original's. A multi-line string literal cannot survive that: its
    /// newlines are its content, not its layout.
    ///
    /// The only shape that genuinely cannot be flattened. A line comment can - it has no
    /// meaning to a compiler, so the mutated copy does without it while the original keeps
    /// it - and that used to be a refusal that stopped the whole run.
    case multilineString = "multiline-string"

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

    /// A project's own mutants that had nothing in this file to anchor to.
    ///
    /// Carried rather than counted, because what somebody needs is *which row*. Code moved
    /// and the row stopped testing anything - and they will be told about it while they
    /// still remember why they moved it, which is the only moment the fix is cheap.
    ///
    /// Apart from ``skips`` rather than inside them: a skip is a decision this tool made
    /// about somebody's code, and this is somebody's own row that no longer applies. The
    /// counts still include it as a skip, so a listing's arithmetic adds up.
    public let unanchored: [UnanchoredMutant]

    /// Where this file's line comments are, in the bytes the user wrote.
    ///
    /// Carried out of discovery because only discovery can know. The mutated copy of a
    /// site is put on one line, and a line comment runs to the end of its line, so the
    /// comment has to come out of the copy - but `//` inside a string literal is not a
    /// comment, and nothing working on bytes can tell the two apart. Discovery has the
    /// tree, so it says exactly which bytes to take out and the splice takes those.
    ///
    /// Every line comment in the file, not only the ones inside a site: which sites there
    /// are is decided after this, and a list that had already been filtered would have to
    /// be filtered again by whoever splices.
    public let lineComments: [SourceSpan]

    /// Records what was found in one file.
    public init(
        path: WorkspaceRelativePath,
        sourceDigest: Digest,
        candidates: [Candidate],
        skips: [Skip],
        unknownSuppressions: [UnknownSuppression] = [],
        unanchored: [UnanchoredMutant] = [],
        lineComments: [SourceSpan] = []
    ) {
        self.path = path
        self.sourceDigest = sourceDigest
        self.candidates = candidates
        self.skips = skips
        self.unknownSuppressions = unknownSuppressions
        self.unanchored = unanchored
        self.lineComments = lineComments
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
            unknownSuppressions: unknownSuppressions,
            unanchored: unanchored,
            lineComments: lineComments
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
