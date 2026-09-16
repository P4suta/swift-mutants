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

    /// Whether this run asked for whole bodies to be replaced.
    ///
    /// Decided before the walk rather than after a candidate exists, because working out
    /// whether a body can be replaced is work worth skipping when nobody asked for it.
    let replacesBodies: Bool

    /// The declaration names this walk is currently inside, outermost first.
    private var declarationPath: [String]

    init(
        locations: SourceLocationConverter,
        suppressions: Suppressions,
        countOnly: Bool = false,
        declarationPath: [String] = [],
        replacesBodies: Bool = false
    ) {
        // One converter per file, built by the caller. Constructing one lays out the whole
        // line table, so building one per node - which is what Muter does - makes discovery
        // quadratic in file size.
        self.locations = locations
        self.suppressions = suppressions
        self.countOnly = countOnly
        self.declarationPath = declarationPath
        self.replacesBodies = replacesBodies
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
        offerBody(of: node)
        return enter(node.name.text)
    }
    override func visitPost(_ node: FunctionDeclSyntax) { leave() }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        offerBody(of: node)
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        offerBody(of: node)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        offerBody(of: node)
        return enter("init")
    }
    override func visitPost(_ node: InitializerDeclSyntax) { leave() }

    // MARK: - Candidates

    /// One end of a collection named as the other.
    ///
    /// The member is what is replaced, not the expression around it, so the receiver keeps
    /// its own bytes and its own mutants: `xs.dropFirst(n + 1).first` has three.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard let other = CollectionEnds.opposite(of: node.declName.baseName.text) else {
            return .visitChildren
        }
        record(
            Rules.endSwap(to: other),
            replacing: Syntax(node.declName.baseName),
            within: Self.guarded(node))
        return .visitChildren
    }

    /// What a guard around a member access has to wrap.
    ///
    /// The member access for a property, and the whole **call** for a method. A ternary
    /// around `xs.dropFirst` alone is a ternary of two *unapplied method references* that
    /// something then calls - which does not type-check, loses every default argument, and
    /// cannot be done at all for a `mutating` method.
    ///
    /// Found by a compile gate. Discovery had no way to know: a member access is a member
    /// access whether or not something calls it, and the catalogue it produced looked
    /// exactly right.
    private static func guarded(_ node: MemberAccessExprSyntax) -> Syntax {
        guard let call = node.parent?.as(FunctionCallExprSyntax.self),
            call.calledExpression.id == node.id
        else {
            return Syntax(node)
        }
        return Syntax(call)
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard let token = node.operator.as(BinaryOperatorExprSyntax.self) else {
            return .visitChildren
        }
        guard let swap = Rules.binaryOperators[token.operator.text] else {
            // Some operators have no other operator to be swapped for and are still worth
            // mutating. `??` is the one: there is no second coalescing operator, but either
            // of its operands standing alone is a mutant, and a sharp one.
            //
            // Reached through this door rather than the one below, which would have called
            // it user-defined - and it is nothing of the kind.
            if token.operator.text == "??" {
                recordCoalescing(of: node)
                return .visitChildren
            }
            if token.operator.text == "..<" || token.operator.text == "..." {
                recordWiderRange(of: node, spelled: token.operator.text)
                return .visitChildren
            }
            // An operator this tool has no meaning for. Swift lets a package define its
            // own, and swapping one for another would be swapping something for something
            // else at random.
            note(.userDefinedOperator, over: Syntax(token), hiding: 0)
            return .visitChildren
        }
        if Rules.isArithmetic(swap), Self.isVisiblyNotANumber(node) {
            // The arithmetic swap is still impossible, and still worth a skip: `+` to `-`
            // on two arrays does not compile. But the operands turning round does, and on
            // a concatenation it is the mutation that matters most.
            note(.nonNumericOperand, over: Syntax(token), hiding: 1)
            if token.operator.text == "+" { recordConcatSwap(of: node) }
            return .visitChildren
        }
        record(swap, replacing: Syntax(token), within: Syntax(node))
        recordPrunes(of: node, spelled: token.operator.text)
        return .visitChildren
    }

    /// Offers a concatenation with its operands the other way round.
    ///
    /// Nothing when they are written the same way. `a + a` is the same program whichever
    /// order it is in, and a mutant nothing can kill only drags a score down - this is the
    /// one case of that the syntax can see, and the compiler cannot be asked about the rest.
    private func recordConcatSwap(of node: InfixOperatorExprSyntax) {
        let left = node.leftOperand.flattenableDescription
        let right = node.rightOperand.flattenableDescription
        guard left != right else { return }
        // Parenthesised, because the operands may be chains themselves. `(x + y) + z`
        // swapped is `z + (x + y)`, and writing that as `z + x + y` re-parses as
        // `(z + x) + y` - the same value only if `+` associates, which it does for the
        // standard library and need not for somebody's own operator. The mutation is meant
        // to be "these two the other way round" and this is that, exactly.
        record(Rules.concatSwap, replacing: Syntax(node), with: "(\(right)) + (\(left))")
    }

    /// Whether an expression is one syntax alone can tell is not arithmetic.
    ///
    /// True only for what can be read off the tree: a string, array or dictionary literal,
    /// or a `+` chain that reaches one. `a + b` could be two integers, so it is false -
    /// the compiler stays the judge of everything this cannot see, which is most of it.
    ///
    /// The recursion is over the folded tree, where `x + y + z` is `(x + y) + z`. A literal
    /// buried on the left of a chain is still what the whole chain produces, and the outer
    /// operator is the one that costs the most: it carries the largest expression.
    static func isVisiblyNotANumber(_ node: some ExprSyntaxProtocol) -> Bool {
        let expression = Self.unwrapped(ExprSyntax(node))
        if expression.is(StringLiteralExprSyntax.self) { return true }
        if expression.is(ArrayExprSyntax.self) { return true }
        if expression.is(DictionaryExprSyntax.self) { return true }
        if let infix = expression.as(InfixOperatorExprSyntax.self) {
            return isVisiblyNotANumber(infix.leftOperand)
                || isVisiblyNotANumber(infix.rightOperand)
        }
        if let assignment = expression.as(SequenceExprSyntax.self) {
            return assignment.elements.contains { isVisiblyNotANumber($0) }
        }
        return false
    }

    /// The expression inside however many layers of parentheses surround it.
    private static func unwrapped(_ expression: ExprSyntax) -> ExprSyntax {
        guard let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
            let only = tuple.elements.first, only.label == nil
        else {
            return expression
        }
        return unwrapped(only.expression)
    }

    /// Offers each operand of a connective as a replacement for the whole expression.
    ///
    /// The operand is taken from the folded tree rather than from the flat sequence
    /// SwiftSyntax parses. `a && b || c` arrives as one `SequenceExprSyntax` with no
    /// grouping at all, so a walk over the raw tree would have to guess which operands
    /// belong to which connective - and would guess wrong in exactly the cases where
    /// precedence is the thing under test.
    /// A range that reaches one element further than it was written to.
    ///
    /// The bound is shifted rather than the operator swapped, because `..<` and `...` build
    /// different types and a ternary guard needs its branches to unify. Shifting keeps the
    /// type by construction.
    ///
    /// Not offered where the bound is visibly not a number: `"a"..<"z"` has no `+ 1`, and a
    /// mutant no compiler accepts costs a build and reports a rejection.
    private func recordWiderRange(of node: InfixOperatorExprSyntax, spelled text: String) {
        guard !Self.isVisiblyNotANumber(node.rightOperand) else {
            note(.nonNumericOperand, over: Syntax(node), hiding: 1)
            return
        }
        record(
            Rules.widenRange,
            replacing: Syntax(node),
            with: "\(node.leftOperand.flattenableDescription) \(text) "
                + "((\(node.rightOperand.flattenableDescription)) + 1)")
    }

    /// The two mutants a coalescing operator has.
    ///
    /// Asymmetric, and the asymmetry is the whole of it. The default side is already the
    /// type the expression has, so it is kept as it stands. The value side is the
    /// *optional*, so keeping it alone is a type error wherever the result is used - it has
    /// to be written as a force unwrap, which has the right type and traps exactly where
    /// nothing tested the absent case.
    ///
    /// Parenthesised, because the operand can be any expression and `a as? T` followed by
    /// `!` is not what anybody meant.
    private func recordCoalescing(of node: InfixOperatorExprSyntax) {
        record(Rules.coalesceToDefault, keeping: Syntax(node.rightOperand), of: Syntax(node))
        record(
            Rules.coalesceToForce,
            replacing: Syntax(node),
            with: "(\(node.leftOperand.flattenableDescription))!")
    }

    private func recordPrunes(of node: InfixOperatorExprSyntax, spelled operatorText: String) {
        guard let prunes = Rules.connectivePrunes[operatorText] else { return }
        for prune in prunes {
            let operand = prune.side == .left ? node.leftOperand : node.rightOperand
            record(prune, keeping: Syntax(operand), of: Syntax(node))
        }
    }

    /// Offers a condition list with one of its clauses taken out.
    ///
    /// `guard`, `if` and `while` all hold one of these, so visiting the list covers the
    /// three at once - and a `case ... where` holds an expression rather than a list, which
    /// is why it is not here.
    ///
    /// One clause at a time, and the whole list is what gets replaced. A span covering one
    /// clause would leave the commas around it behind and produce `if , b`; a mutant that
    /// dropped several at once would ask about none of them in particular.
    override func visit(_ node: ConditionElementListSyntax) -> SyntaxVisitorContinueKind {
        recordClauseDrops(of: node)
        return .visitChildren
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        recordNoOp(of: node.conditions, becoming: Rules.guardNoOp)
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        recordNoOp(of: node.conditions, becoming: Rules.ifNoOp)
        return .visitChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        // `false`, the same as an `if`, because a loop's condition is also the case that
        // runs. The hang people reach for as an objection is `while true`, and that is the
        // other column - the one this family does not generate for any keyword.
        recordNoOp(of: node.conditions, becoming: Rules.ifNoOp)
        return .visitChildren
    }

    override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard let swap = Rules.booleanLiterals[node.literal.text] else { return .skipChildren }
        if Self.isWholeConditionOfALoop(node) {
            note(.loopConditionLiteral, over: Syntax(node), hiding: 1)
            return .skipChildren
        }
        record(swap, replacing: Syntax(node.literal), within: Syntax(node))
        return .skipChildren
    }

    /// Whether this literal is the entire condition of a `while` or `repeat`.
    ///
    /// The whole condition, not a part of one: `while ready && true` has a decision in it,
    /// and the literal is part of that decision rather than a spelling of "loop".
    ///
    /// Walking up rather than down, because the shapes differ - `while` holds a list of
    /// condition elements and `repeat` holds one expression - and both are two or three
    /// nodes above the literal with nothing in between that changes the answer.
    private static func isWholeConditionOfALoop(_ node: BooleanLiteralExprSyntax) -> Bool {
        var child = Syntax(node)
        while let parent = child.parent {
            if let loop = parent.as(RepeatStmtSyntax.self) {
                return loop.condition.id == child.id
            }
            if let element = parent.as(ConditionElementSyntax.self) {
                guard case .expression(let condition) = element.condition,
                    condition.id == child.id
                else {
                    return false
                }
                return element.parent?.parent?.is(WhileStmtSyntax.self) ?? false
            }
            // Anything that is not one of those - an operator, a call, a member access -
            // means the literal is inside an expression rather than being one.
            guard parent.is(ConditionElementListSyntax.self) else { return false }
            child = parent
        }
        return false
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

    /// Records a region as passed over.
    ///
    /// Kept even when it hid nothing, because the record is of the rule having matched,
    /// and "this rule fires on four hundred sites, of which three hundred held nothing" is
    /// exactly what a reader checking whether a rule is too broad needs. The exception is
    /// an operator this tool has no meaning for, which is not a decision worth a line: it
    /// is a fact about somebody's own operator.
    /// Records one declaration this rule could not offer.
    ///
    /// One, because a body is one site: the count is what the decision cost there, and a
    /// body it could not replace cost exactly the one mutant it would have made.
    func note(_ reason: SkipReason, at node: Syntax) {
        note(reason, over: node, hiding: 1)
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
                form: .expression,
                enclosingDeclaration: declarationPath.joined(separator: ".")
            )
        )
    }

    /// Records a prune: the expression replaced by one of its own operands.
    private func record(_ prune: Rules.Prune, keeping operand: Syntax, of expression: Syntax) {
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
                enclosingDeclaration: declarationPath.joined(separator: ".")
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
                enclosingDeclaration: declarationPath.joined(separator: ".")
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
