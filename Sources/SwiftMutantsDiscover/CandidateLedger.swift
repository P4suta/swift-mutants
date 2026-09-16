// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftSyntax

/// What a walk writes down.
///
/// Apart from the walk itself because the two answer different questions. The walker
/// decides which sites a rule matches; this decides what a match becomes - a candidate, a
/// skip, or nothing. Every rule arrives here, so the suppression check, the declaration
/// path and the span arithmetic are written once rather than once per rule, and a rule
/// added later cannot forget any of them.
final class CandidateLedger {

    private(set) var candidates: [Candidate] = []
    private(set) var skips: [Skip] = []

    let locations: SourceLocationConverter
    let suppressions: Suppressions

    /// Whether this walk is the throwaway one a skip uses to count what it is hiding.
    ///
    /// A counting walk produces candidates and no skips, so that the count is of what the
    /// region *would* have yielded rather than of what a second suppression pass decides.
    let countOnly: Bool

    /// The declaration names the walk is currently inside, outermost first.
    private(set) var path: [String]

    init(
        locations: SourceLocationConverter,
        suppressions: Suppressions,
        countOnly: Bool,
        path: [String]
    ) {
        // One converter per file, built by the caller. Constructing one lays out the whole
        // line table, so building one per node - which is what Muter does - makes discovery
        // quadratic in file size.
        self.locations = locations
        self.suppressions = suppressions
        self.countOnly = countOnly
        self.path = path
    }

    // MARK: - Where the walk is

    func enter(_ name: String) {
        path.append(name)
    }

    func leave() {
        if !path.isEmpty { path.removeLast() }
    }

    // MARK: - What it found

    /// Records one declaration this rule could not offer.
    ///
    /// One, because a body is one site: the count is what the decision cost there, and a
    /// body it could not replace cost exactly the one mutant it would have made.
    func note(_ reason: SkipReason, at node: Syntax) {
        note(reason, over: node, hiding: 1)
    }

    /// Records a region as passed over.
    ///
    /// Kept even when it hid nothing, because the record is of the rule having matched,
    /// and "this rule fires on four hundred sites, of which three hundred held nothing" is
    /// exactly what a reader checking whether a rule is too broad needs. The exception is
    /// an operator this tool has no meaning for, which is not a decision worth a line: it
    /// is a fact about somebody's own operator.
    func note(_ reason: SkipReason, over node: Syntax, hiding: Int) {
        guard !countOnly else { return }
        if reason == .userDefinedOperator, hiding == 0 { return }
        guard let region = Self.span(of: node) else { return }
        skips.append(Skip(reason: reason, span: region, candidatesHidden: hiding))
    }

    func record(_ swap: Rules.Swap, replacing token: Syntax, within expression: Syntax) {
        guard let edit = Self.span(of: token), let wrapped = Self.span(of: expression) else {
            return
        }
        if !countOnly, isSuppressed(swap.family, at: token) {
            skips.append(Skip(reason: .disabledByComment, span: edit, candidatesHidden: 1))
            return
        }
        candidates.append(
            Candidate(
                rule: Rules.identifier(for: swap),
                span: edit,
                original: token.trimmedDescription,
                replacement: swap.replacement,
                guardSpan: wrapped,
                form: .expression,
                enclosingDeclaration: path.joined(separator: ".")
            )
        )
    }

    /// Records a prune: the expression replaced by one of its own operands.
    func record(_ prune: Rules.Prune, keeping operand: Syntax, of expression: Syntax) {
        guard let region = Self.span(of: expression) else { return }
        if !countOnly, isSuppressed(prune.family, at: expression) {
            skips.append(Skip(reason: .disabledByComment, span: region, candidatesHidden: 1))
            return
        }
        candidates.append(
            Candidate(
                rule: Rules.identifier(for: prune),
                span: region,
                original: expression.trimmedDescription,
                replacement: operand.flattenableDescription,
                guardSpan: region,
                form: .expression,
                enclosingDeclaration: path.joined(separator: ".")
            )
        )
    }

    /// Records a statement that does not run.
    ///
    /// The span is the statement itself and the replacement is empty: the guard is written
    /// around what is there, so the original keeps every byte and every newline it had and
    /// only its first and last lines gain any text.
    func record(_ prune: Rules.Prune, skipping statement: Syntax) {
        guard let span = Self.span(of: statement) else { return }
        if !countOnly, isSuppressed(prune.family, at: statement) {
            skips.append(Skip(reason: .disabledByComment, span: span, candidatesHidden: 1))
            return
        }
        candidates.append(
            Candidate(
                rule: Rules.identifier(for: prune),
                span: span,
                original: statement.trimmedDescription,
                replacement: "",
                guardSpan: span,
                form: .skipping,
                enclosingDeclaration: path.joined(separator: ".")
            )
        )
    }

    /// Records a mutant whose guard is a statement in front of a body.
    ///
    /// The span is empty and sits just after the opening brace, which is the whole of the
    /// design: an empty span replaces no bytes, so the body below it does not move and
    /// every line number in the file is what it was. The guard covers the body, so a mutant
    /// that stops it is attributed to the declaration it stopped.
    func record(
        _ prune: Rules.Prune, inside interior: SourceSpan, of region: Syntax, doing: String
    ) {
        // The guard covers what is *between* the braces, never the braces themselves. A
        // guard that covered the whole block would be spliced in front of the `{`, and the
        // declaration would read `func f() if g { return } { ... }` - two things on a line
        // where Swift allows one. Found by a compile gate; discovery could not see it,
        // because a span covering a block is a perfectly ordinary span.
        let covered = interior
        guard let here = SourceSpan(start: interior.start, end: interior.start) else { return }
        if !countOnly, isSuppressed(prune.family, at: region) {
            skips.append(Skip(reason: .disabledByComment, span: covered, candidatesHidden: 1))
            return
        }
        candidates.append(
            Candidate(
                rule: Rules.identifier(for: prune),
                span: here,
                original: "",
                replacement: doing,
                guardSpan: covered,
                form: .statement,
                enclosingDeclaration: path.joined(separator: ".")
            )
        )
    }

    /// Records a prune whose replacement is built rather than taken from the tree.
    ///
    /// A condition list with one clause removed is not a subtree of anything, so there is
    /// no node to point at - only text to put in its place.
    func record(_ prune: Rules.Prune, replacing region: Syntax, with text: String) {
        guard let span = Self.span(of: region) else { return }
        if !countOnly, isSuppressed(prune.family, at: region) {
            skips.append(Skip(reason: .disabledByComment, span: span, candidatesHidden: 1))
            return
        }
        candidates.append(
            Candidate(
                rule: Rules.identifier(for: prune),
                span: span,
                original: region.trimmedDescription,
                replacement: text,
                guardSpan: span,
                form: .expression,
                enclosingDeclaration: path.joined(separator: ".")
            )
        )
    }

    private func isSuppressed(_ family: String, at token: Syntax) -> Bool {
        let position = token.positionAfterSkippingLeadingTrivia
        return suppressions.disables(family, onLine: locations.location(for: position).line)
    }

    private static func span(of node: Syntax) -> SourceSpan? {
        let range = node.trimmedRange
        return SourceSpan(start: range.lowerBound.utf8Offset, end: range.upperBound.utf8Offset)
    }
}
