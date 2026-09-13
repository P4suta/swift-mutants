// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftSyntax

/// Walks a folded tree, collecting candidates and naming what it passed over.
///
/// A `SyntaxVisitor` subclass rather than a value, because that is what `SwiftSyntax`
/// offers and because these are not `Sendable`: one is made per file, used once, and thrown
/// away.
final class CandidateWalker: SyntaxVisitor {

    private(set) var candidates: [Candidate] = []
    private(set) var skips: [Skip] = []

    private let locations: SourceLocationConverter
    private let suppressions: Suppressions

    /// Whether this walk is the throwaway one a skip uses to count what it is hiding.
    ///
    /// A counting walk produces candidates and no skips, so that the count is of what the
    /// region *would* have yielded rather than of what a second suppression pass decides.
    private let countOnly: Bool

    /// The declaration names this walk is currently inside, outermost first.
    private var declarationPath: [String]

    init(
        locations: SourceLocationConverter,
        suppressions: Suppressions,
        countOnly: Bool = false,
        declarationPath: [String] = []
    ) {
        // One converter per file, built by the caller. Constructing one lays out the whole
        // line table, so building one per node - which is what Muter does - makes discovery
        // quadratic in file size.
        self.locations = locations
        self.suppressions = suppressions
        self.countOnly = countOnly
        self.declarationPath = declarationPath
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Regions passed over whole

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        skipRegion(Syntax(node), reason: .macroExpansion)
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        skipRegion(Syntax(node), reason: .macroExpansion)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard AridRules.isArid(node) else { return .visitChildren }
        return skipRegion(Syntax(node), reason: .arid)
    }

    // MARK: - Declaration names

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node.name.text)
    }
    override func visitPost(_ node: StructDeclSyntax) { leave() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node.name.text)
    }
    override func visitPost(_ node: ClassDeclSyntax) { leave() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node.name.text)
    }
    override func visitPost(_ node: EnumDeclSyntax) { leave() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node.extendedType.trimmedDescription)
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { leave() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node.name.text)
    }
    override func visitPost(_ node: FunctionDeclSyntax) { leave() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("init")
    }
    override func visitPost(_ node: InitializerDeclSyntax) { leave() }

    // MARK: - Candidates

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard let token = node.operator.as(BinaryOperatorExprSyntax.self) else {
            return .visitChildren
        }
        guard let swap = Rules.binaryOperators[token.operator.text] else {
            // An operator this tool has no meaning for. Swift lets a package define its
            // own, and swapping one for another would be swapping something for something
            // else at random.
            note(.userDefinedOperator, over: Syntax(token), hiding: 0)
            return .visitChildren
        }
        record(swap, replacing: Syntax(token), within: Syntax(node))
        return .visitChildren
    }

    override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard let swap = Rules.booleanLiterals[node.literal.text] else { return .skipChildren }
        record(swap, replacing: Syntax(node.literal), within: Syntax(node))
        return .skipChildren
    }

    // MARK: - Bookkeeping

    private func enter(_ name: String) -> SyntaxVisitorContinueKind {
        declarationPath.append(name)
        return .visitChildren
    }

    private func leave() {
        if !declarationPath.isEmpty { declarationPath.removeLast() }
    }

    /// Records a region as passed over, counting what it would have produced.
    ///
    /// The count is the point. "Sixty candidates were suppressed as arid" is an answer;
    /// "some were suppressed" is not, and a reader who suspects a rule is too broad has no
    /// way to check without it.
    private func skipRegion(_ node: Syntax, reason: SkipReason) -> SyntaxVisitorContinueKind {
        // A counting walk descends into what a real walk would pass over: the number it is
        // after is what the region *would* have yielded, which is the only number that
        // answers "is this rule too broad".
        guard !countOnly else { return .visitChildren }
        let counter = CandidateWalker(
            locations: locations,
            suppressions: suppressions,
            countOnly: true,
            declarationPath: declarationPath
        )
        counter.walk(node)
        note(reason, over: node, hiding: counter.candidates.count)
        return .skipChildren
    }

    private func note(_ reason: SkipReason, over node: Syntax, hiding: Int) {
        guard !countOnly else { return }
        if reason == .userDefinedOperator, hiding == 0 { return }
        guard let region = Self.span(of: node) else { return }
        skips.append(Skip(reason: reason, span: region, candidatesHidden: hiding))
    }

    private func record(_ swap: Rules.Swap, replacing token: Syntax, within expression: Syntax) {
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
                enclosingDeclaration: declarationPath.joined(separator: ".")
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
