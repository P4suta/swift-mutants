// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftSyntax

/// Finding statements that could simply not run.
///
/// The plainest question in mutation testing - if this line never ran, would anything
/// notice? - and by volume the largest family there is.
///
/// What makes it delicate is that a statement is the richest site in a program. It can bind
/// a name the rest of the block needs, it can be the one thing keeping a `guard` from
/// falling through, and it can be an implicit return wearing a call's clothes. Each of those
/// is a program that stops compiling rather than a mutant, so the walk starts from what is
/// *safe* and adds nothing it cannot argue for.
extension CandidateWalker {

    /// Offers each statement in a block that could be skipped without changing what the
    /// block means to everything around it.
    func offerSkippable(in block: CodeBlockItemListSyntax, of parent: Syntax) {
        guard skipsStatements else { return }
        // A block of one statement is never touched. In a function body it is the implicit
        // return, in a `guard` it is the only thing stopping a fall-through, and in a
        // closure it is both - and none of those is a statement this rule may skip.
        guard block.count > 1 else { return }
        for item in block {
            guard let rule = Self.skippable(item) else { continue }
            record(rule, skipping: Syntax(item))
        }
    }

    /// Which rule a statement is for, or nothing when it is not one this may skip.
    ///
    /// Only two shapes, and both bind nothing: a call whose value is discarded, and an
    /// assignment to something that already exists. Every other statement either introduces
    /// a name, decides control flow, or is a declaration - and skipping any of them is a
    /// different program rather than a mutated one.
    private static func skippable(_ item: CodeBlockItemSyntax) -> Rules.Prune? {
        guard case .expr(let expression) = item.item else { return nil }
        if expression.is(FunctionCallExprSyntax.self) { return Rules.skipCall }
        // `try f()` and `await f()` as statements: the value is still discarded.
        if let tried = expression.as(TryExprSyntax.self) {
            return tried.expression.is(FunctionCallExprSyntax.self) ? Rules.skipCall : nil
        }
        if let awaited = expression.as(AwaitExprSyntax.self) {
            return awaited.expression.is(FunctionCallExprSyntax.self) ? Rules.skipCall : nil
        }
        // An assignment arrives folded as an infix `=`, or as a compound `+=`.
        if let infix = expression.as(InfixOperatorExprSyntax.self) {
            if infix.operator.is(AssignmentExprSyntax.self) { return Rules.skipAssignment }
            if let token = infix.operator.as(BinaryOperatorExprSyntax.self),
                token.operator.text.count > 1, token.operator.text.hasSuffix("=")
            {
                return Rules.skipAssignment
            }
        }
        return nil
    }
}
