// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftSyntax

extension CandidateWalker {

    func offerSkippable(in block: CodeBlockItemListSyntax) {
        guard skipsStatements else { return }
        // Keep implicit returns and the mandatory exit from a guard body.
        guard block.count > 1 || Self.mayFallOut(of: block) else { return }
        for item in block {
            guard let rule = Self.skippable(item) else { continue }
            ledger.record(rule, skipping: Syntax(item))
        }
    }

    private static func mayFallOut(of block: CodeBlockItemListSyntax) -> Bool {
        guard let code = block.parent?.as(CodeBlockSyntax.self) else {
            // Not a braced block: a `switch` case's statement list, which may be empty.
            return block.parent?.is(SwitchCaseSyntax.self) == true
        }
        guard let owner = code.parent else { return false }
        let carriesTheValue =
            owner.is(FunctionDeclSyntax.self)
            || owner.is(InitializerDeclSyntax.self)
            || owner.is(DeinitializerDeclSyntax.self)
            || owner.is(AccessorDeclSyntax.self)
            || owner.is(ClosureExprSyntax.self)
            || owner.is(GuardStmtSyntax.self)
        return !carriesTheValue
    }

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
