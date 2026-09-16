// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftSyntax

/// Asking whether a condition is load-bearing.
///
/// Two families and one question. A clause of a list is dropped by replacing it with
/// `true`; a condition that has only one clause is replaced by whichever constant makes its
/// keyword a no-op. Together they cover where conditions actually are, and apart they can
/// be turned off apart - a project that wants the operator swaps in its conditions but not
/// these should not have to choose.
extension CandidateWalker {

    /// Each clause of a list that can be dropped, dropped.
    ///
    /// Dropping a clause *is* replacing it with `true`, and that matters: a condition list
    /// is not an expression, so it cannot be wrapped in a ternary, and a mutant that
    /// rewrote the list would need a statement-level guard. One clause is an expression,
    /// and `guard a, (awake ? true : b), c else` is both ordinary Swift and exactly the
    /// same program as `guard a, c else`.
    ///
    /// Only plain expressions. A binding - `let x = f()`, or a `case` pattern - is named by
    /// the clauses after it and by the body, and is not an expression to begin with. The
    /// compiler would say so and validation would drop the mutant, but a compile is the
    /// expensive thing here and this is knowable from the syntax.
    func recordClauseDrops(of node: ConditionElementListSyntax) {
        let clauses = Array(node)
        guard clauses.count > 1 else { return }
        for clause in clauses {
            guard case .expression(let expression) = clause.condition else { continue }
            ledger.record(Rules.dropCondition, replacing: Syntax(expression), with: "true")
        }
    }

    /// Offers a single-clause condition replaced by the constant that makes it a no-op.
    ///
    /// One clause only. A list is the clause-dropping family's question, asked of each
    /// clause in turn, and asking it here as well would ask the same thing twice and count
    /// it twice in the score.
    ///
    /// Not a binding: the body names what it bound, so a constant in its place does not
    /// compile. A single-clause `if let` therefore yields nothing, which is right.
    ///
    /// Not a literal either - a condition that is already a constant is already this
    /// mutant, and the boolean literal family has it.
    ///
    /// A `while` is here and takes `false`, because a loop's condition is the case that
    /// runs. The endless loop people reach for as an objection is `while true`, which is
    /// the other column - the same column as `guard false` and `if true`, and this family
    /// generates none of them.
    func recordNoOp(of conditions: ConditionElementListSyntax, becoming constant: String) {
        let clauses = Array(conditions)
        guard clauses.count == 1, let only = clauses.first,
            case .expression(let expression) = only.condition,
            expression.as(BooleanLiteralExprSyntax.self) == nil
        else { return }
        ledger.record(Rules.neverDecides, replacing: Syntax(expression), with: constant)
    }
}
