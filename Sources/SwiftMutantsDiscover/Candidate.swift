// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// A source edit and the enclosing region its runtime guard needs.
public struct Candidate: Sendable, Hashable {
    /// The rule that produced the edit.
    public let rule: RuleIdentifier
    /// The UTF-8 bytes to replace.
    public let span: SourceSpan
    /// The original source text.
    public let original: String
    /// The replacement source text.
    public let replacement: String
    /// The expression or statement a guard wraps.
    public let guardSpan: SourceSpan
    /// The syntax needed to activate the edit.
    public let form: GuardForm
    /// The enclosing declaration's syntactic name.
    public let enclosingDeclaration: String
}

/// The two guard shapes used by the fixed mutation families.
public enum GuardForm: String, Sendable, Hashable, Codable, CaseIterable {
    /// A ternary selects a mutated expression or its original.
    case expression
    /// A condition prevents an existing statement from running.
    case skipping
}

/// A source region omitted from the mutation candidates.
public struct Skip: Sendable, Hashable {
    /// The reason for omitting the region.
    public let reason: SkipReason
    /// The omitted UTF-8 byte range.
    public let span: SourceSpan
    /// The number of candidates omitted.
    public let candidatesHidden: Int

    /// Records an omitted region.
    public init(reason: SkipReason, span: SourceSpan, candidatesHidden: Int) {
        self.reason = reason
        self.span = span
        self.candidatesHidden = candidatesHidden
    }
}

/// The reasons supported discovery rules omit a region.
public enum SkipReason: String, Sendable, Hashable, CaseIterable {
    /// Logging, assertions, and similar calls excluded by the arid-code rules.
    case arid
    /// Arguments expanded by a macro.
    case macroExpansion = "macro-expansion"
    /// A source suppression comment excluded the candidate.
    case disabledByComment = "disabled-by-comment"
    /// An operator without a supported mutation rule.
    case userDefinedOperator = "user-defined-operator"
    /// Arithmetic with an operand visibly containing a string or collection.
    case nonNumericOperand = "non-numeric-operand"
    /// A Boolean literal forming the whole loop condition.
    case loopConditionLiteral = "loop-condition-literal"
    /// A guard region containing a multiline string literal.
    case multilineString = "multiline-string"
}

/// Mutation candidates and source facts collected from one file.
public struct FileDiscovery: Sendable, Hashable {
    /// The package-relative source path.
    public let path: WorkspaceRelativePath
    /// A digest of the original UTF-8 source.
    public let sourceDigest: Digest
    /// Candidates in source order.
    public let candidates: [Candidate]
    /// Regions omitted from discovery.
    public let skips: [Skip]
    /// Suppression comments naming unsupported families.
    public let unknownSuppressions: [UnknownSuppression]
    /// Line-comment byte ranges used when flattening a mutated expression.
    public let lineComments: [SourceSpan]

    /// Records the discovery result for a source file.
    public init(
        path: WorkspaceRelativePath,
        sourceDigest: Digest,
        candidates: [Candidate],
        skips: [Skip],
        unknownSuppressions: [UnknownSuppression] = [],
        lineComments: [SourceSpan] = []
    ) {
        self.path = path
        self.sourceDigest = sourceDigest
        self.candidates = candidates
        self.skips = skips
        self.unknownSuppressions = unknownSuppressions
        self.lineComments = lineComments
    }

    /// Selects candidates while preserving the original source facts.
    public func keeping(_ isKept: (Candidate) -> Bool) -> Self {
        Self(
            path: path,
            sourceDigest: sourceDigest,
            candidates: candidates.filter(isKept),
            skips: skips,
            unknownSuppressions: unknownSuppressions,
            lineComments: lineComments
        )
    }
}

/// A suppression comment naming an unsupported mutation family.
public struct UnknownSuppression: Sendable, Hashable {
    /// The source line, starting at one.
    public let line: Int
    /// The unsupported family name.
    public let name: String

    /// Records the source line and family name.
    public init(line: Int, name: String) {
        self.line = line
        self.name = name
    }
}
