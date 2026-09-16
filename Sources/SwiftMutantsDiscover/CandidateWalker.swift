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

    /// What this walk writes down. Shared with the throwaway counting walks a skip makes,
    /// only in the sense that each gets one of its own: a ledger is never handed around.
    let ledger: CandidateLedger

    /// Whether this run asked for statements to be skipped.
    ///
    /// A tier rather than a flag, and its own question here so the walk can decide before
    /// it looks at a block rather than after it has built candidates nobody wanted.
    let skipsStatements: Bool

    /// Whether this run asked for whole bodies to be replaced.
    ///
    /// Decided before the walk rather than after a candidate exists, because working out
    /// whether a body can be replaced is work worth skipping when nobody asked for it.
    let replacesBodies: Bool

    var candidates: [Candidate] { ledger.candidates }
    var skips: [Skip] { ledger.skips }

    init(
        locations: SourceLocationConverter,
        suppressions: Suppressions,
        countOnly: Bool = false,
        declarationPath: [String] = [],
        replacesBodies: Bool = false,
        skipsStatements: Bool = false
    ) {
        self.ledger = CandidateLedger(
            locations: locations,
            suppressions: suppressions,
            countOnly: countOnly,
            path: declarationPath
        )
        self.replacesBodies = replacesBodies
        self.skipsStatements = skipsStatements
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

    /// A pattern's extra condition, made always or never to hold.
    ///
    /// One visit for every place Swift allows the clause - a `switch` case, a `for`, a
    /// `catch` - because they are the same clause asking the same question, and a rule that
    /// knew only about `switch` would pass over the other two in silence.
    override func visit(_ node: WhereClauseSyntax) -> SyntaxVisitorContinueKind {
        let condition = Syntax(node.condition)
        // Nothing when the clause is already the constant: `where true` replaced by `true`
        // is a mutant that cannot fail.
        let written = node.condition.trimmedDescription
        if written != "true" {
            ledger.record(Rules.patternAlwaysMatches, replacing: condition, within: condition)
        }
        if written != "false" {
            ledger.record(Rules.patternNeverMatches, replacing: condition, within: condition)
        }
        return .visitChildren
    }

    /// An optional `try` that fails every time.
    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.questionOrExclamationMark?.tokenKind == .postfixQuestionMark else {
            return .visitChildren
        }
        ledger.record(Rules.tryOptionalFails, replacing: Syntax(node), with: "nil")
        return .visitChildren
    }

    /// An integer literal one either side of what was written.
    override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard let value = Int(node.literal.text.filter { $0 != "_" }) else {
            // A literal written in another base, or one too large for this to reason about.
            // Leaving it alone is right either way: a hexadecimal mask moved by one is not
            // an off-by-one, it is a different mask.
            return .visitChildren
        }
        ledger.record(Rules.literalOneMore, replacing: Syntax(node), with: "\(value + 1)")
        // Never below zero. `-1` is a different kind of number from a count or an index,
        // and on either it is a value the program was never going to see.
        if value > 0 {
            ledger.record(Rules.literalOneLess, replacing: Syntax(node), with: "\(value - 1)")
        }
        return .visitChildren
    }

    /// A negation taken away.
    override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.operator.text == "-",
            // Not on a literal: the sign is part of how the number is written, and the
            // literal rules are already asking about the value.
            !node.expression.is(IntegerLiteralExprSyntax.self),
            !node.expression.is(FloatLiteralExprSyntax.self)
        else { return .visitChildren }
        ledger.record(
            Rules.dropNegation,
            replacing: Syntax(node),
            with: node.expression.flattenableDescription)
        return .visitChildren
    }

    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        offerSkippable(in: node, of: Syntax(node))
        return .visitChildren
    }

    /// One end of a collection named as the other.
    ///
    /// The member is what is replaced, not the expression around it, so the receiver keeps
    /// its own bytes and its own mutants: `xs.dropFirst(n + 1).first` has three.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard let other = CollectionEnds.opposite(of: node.declName.baseName.text) else {
            return .visitChildren
        }
        ledger.record(
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
            ledger.note(.userDefinedOperator, over: Syntax(token), hiding: 0)
            return .visitChildren
        }
        if Rules.isArithmetic(swap), Self.isVisiblyNotANumber(node) {
            // The arithmetic swap is still impossible, and still worth a skip: `+` to `-`
            // on two arrays does not compile. But the operands turning round does, and on
            // a concatenation it is the mutation that matters most.
            ledger.note(.nonNumericOperand, over: Syntax(token), hiding: 1)
            if token.operator.text == "+" { recordConcatSwap(of: node) }
            return .visitChildren
        }
        ledger.record(swap, replacing: Syntax(token), within: Syntax(node))
        recordPrunes(of: node, spelled: token.operator.text)
        return .visitChildren
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
            ledger.note(.loopConditionLiteral, over: Syntax(node), hiding: 1)
            return .skipChildren
        }
        ledger.record(swap, replacing: Syntax(node.literal), within: Syntax(node))
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
        ledger.enter(name)
        return .visitChildren
    }

    private func leave() {
        ledger.leave()
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
        guard !ledger.countOnly else { return .visitChildren }
        let counter = CandidateWalker(
            locations: ledger.locations,
            suppressions: ledger.suppressions,
            countOnly: true,
            declarationPath: ledger.path
        )
        counter.walk(node)
        ledger.note(reason, over: node, hiding: counter.candidates.count)
        return .skipChildren
    }
}
