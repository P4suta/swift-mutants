// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftSyntax

/// Expression-based rules for Boolean operand pruning and concatenation order.
extension CandidateWalker {

    /// Offers a concatenation with its operands the other way round.
    ///
    /// Nothing when they are written the same way.
    /// `a + a` is the same program whichever order it is in, and a mutant nothing can kill only drags a score down - this is the one case of that the syntax can see, and the compiler cannot be asked about the rest.
    func recordConcatSwap(of node: InfixOperatorExprSyntax) {
        let left = node.leftOperand.flattenableDescription
        let right = node.rightOperand.flattenableDescription
        guard left != right else { return }
        // Parenthesised, because the operands may be chains themselves.
        // `(x + y) + z` swapped is `z + (x + y)`, and writing that as `z + x + y` re-parses as `(z + x) + y` - the same value only if `+` associates, which it does for the standard library and need not for somebody's own operator.
        // The mutation is meant to be "these two the other way round" and this is that, exactly.
        ledger.record(Rules.concatSwap, replacing: Syntax(node), with: "(\(right)) + (\(left))")
    }

    /// Whether an expression is one syntax alone can tell is not arithmetic.
    ///
    /// True only for what can be read off the tree: a string, array or dictionary literal,
    /// or a `+` chain that reaches one.
    /// `a + b` could be two integers, so it is false - the compiler stays the judge of everything this cannot see, which is most of it.
    ///
    /// The recursion is over the folded tree, where `x + y + z` is `(x + y) + z`.
    /// A literal buried on the left of a chain is still what the whole chain produces, and the outer operator is the one that costs the most: it carries the largest expression.
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

    /// Offers either operand as a replacement for a connective expression.
    func recordPrunes(of node: InfixOperatorExprSyntax, spelled operatorText: String) {
        guard let prunes = Rules.connectivePrunes[operatorText] else { return }
        for prune in prunes {
            let operand = prune.side == .left ? node.leftOperand : node.rightOperand
            ledger.record(prune, keeping: Syntax(operand), of: Syntax(node))
        }
    }
}
