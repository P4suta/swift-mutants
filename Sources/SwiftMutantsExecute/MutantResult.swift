// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// What became of one mutant.
public struct MutantResult: Sendable, Hashable {

    /// Which mutant.
    public let identity: MutantIdentity

    /// Where it is in the file the user wrote.
    public let path: WorkspaceRelativePath

    /// Which rule produced it.
    public let rule: RuleIdentifier

    /// Where in that file.
    public let span: SourceSpan

    /// The bytes it replaced, as the user wrote them.
    public let original: String

    /// The bytes it put there instead.
    public let replacement: String

    /// What the tests said about it.
    public let verdict: Verdict

    /// How many times it had to be run.
    ///
    /// More than once means the first attempt ran out of time and was tried again on a
    /// quiet machine. That is worth seeing: a deadline met under load says nothing about
    /// a mutant, and a report that hid the retry would look like an answer it is not.
    public let attempts: Int

    /// Which guard in the instrumented tree it is.
    ///
    /// The number the runtime switches on, which is what `SWIFT_MUTANTS_ACTIVE` takes. A
    /// mutant's identity is its name everywhere a person or a cache is concerned; this is
    /// the one thing that needs the position, and it is needed because a command that wakes
    /// this mutant again cannot be written without it.
    public let index: UInt32

    /// Records what became of one mutant.
    public init(
        identity: MutantIdentity,
        path: WorkspaceRelativePath,
        rule: RuleIdentifier,
        span: SourceSpan,
        original: String = "",
        replacement: String = "",
        verdict: Verdict,
        attempts: Int,
        index: UInt32 = 0
    ) {
        self.identity = identity
        self.path = path
        self.rule = rule
        self.span = span
        self.original = original
        self.replacement = replacement
        self.verdict = verdict
        self.attempts = attempts
        self.index = index
    }
}
