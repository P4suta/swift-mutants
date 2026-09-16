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
        // A block of one statement is touched only where falling out of it is what the
        // block does anyway. In a function body that statement is the implicit return, in a
        // `guard` it is the only thing stopping a fall-through, and in a closure it is
        // both. In an `if`, a loop, a `do` or a `catch` it is none of those - and a `catch`
        // that does nothing is one of the best mutants there is, because it asks whether
        // anything tests that errors are handled at all.
        guard block.count > 1 || Self.mayFallOut(of: block) else { return }
        for item in block {
            guard let rule = Self.skippable(item) else { continue }
            record(rule, skipping: Syntax(item))
        }
    }

    /// Whether a block may simply end without its statements having run.
    ///
    /// Decided from what encloses it rather than from what is in it. A `CodeBlockSyntax`
    /// under a function, an initialiser or an accessor carries that declaration's value or
    /// its effect; under a `guard` it is the only exit; a closure's body is its value. Every
    /// other block - `if`, `else`, a loop, `do`, `catch` - is a block a program falls out
    /// of, and skipping its only statement is a mutant rather than a different program.
    ///
    /// A `switch` case is the other shape: its statements are not in a `CodeBlockSyntax` at
    /// all, and a case that does nothing still matches.
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
