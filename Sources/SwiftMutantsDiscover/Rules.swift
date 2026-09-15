// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore

/// The rules that swap one operator or literal for another.
///
/// A table rather than a chain of conditions, so that the catalogue is a thing a reader can
/// see the whole of, and so that adding a rule is adding a row.
enum Rules {

    /// One swap: what it matches, what it produces, and what it is called.
    struct Swap: Sendable {
        let replacement: String
        let name: String
        let family: String
    }

    /// Comparisons. The boundary shifts and the equality flip only: the full six-way
    /// replacement is where most of a catalogue's redundancy comes from, and the
    /// `-> true` / `-> false` forms are subsumed by condition negation.
    static let comparisons: [String: Swap] = [
        "<": Swap(replacement: "<=", name: "lt-to-le", family: "comparison"),
        "<=": Swap(replacement: "<", name: "le-to-lt", family: "comparison"),
        ">": Swap(replacement: ">=", name: "gt-to-ge", family: "comparison"),
        ">=": Swap(replacement: ">", name: "ge-to-gt", family: "comparison"),
        "==": Swap(replacement: "!=", name: "eq-to-neq", family: "comparison"),
        "!=": Swap(replacement: "==", name: "neq-to-eq", family: "comparison"),
    ]

    /// The logical connectives.
    static let connectives: [String: Swap] = [
        "&&": Swap(replacement: "||", name: "and-to-or", family: "boolean-connective"),
        "||": Swap(replacement: "&&", name: "or-to-and", family: "boolean-connective"),
    ]

    /// Arithmetic, paired rather than exhaustive.
    ///
    /// `+` becomes `-` and `-` becomes `+`; neither also becomes `*`, `/` and `%`. The full
    /// cross-product is where a catalogue's redundancy comes from - several mutants at one
    /// site that one test kills together - and Google's six years of measurements on a
    /// two-billion-line monorepo put exhaustive operator replacement at the bottom of the
    /// productivity table. `%` pairs with `*` because dividing is the operation it is
    /// nearly, and `n % k` becoming `n * k` is caught by anything that checks a range.
    ///
    /// Nothing here asks what the operands are. `+` on `String` is concatenation and `-` is
    /// not defined for it, so that mutant does not compile - and the compiler is what says
    /// so, in one typecheck, for the whole file at once. A rule that guessed at types
    /// without having any would guess wrong in both directions: refusing mutants that
    /// compile, and emitting ones that do not for a type it had never heard of.
    static let arithmetic: [String: Swap] = [
        "+": Swap(replacement: "-", name: "add-to-sub", family: "integer-arithmetic"),
        "-": Swap(replacement: "+", name: "sub-to-add", family: "integer-arithmetic"),
        "*": Swap(replacement: "/", name: "mul-to-div", family: "integer-arithmetic"),
        "/": Swap(replacement: "*", name: "div-to-mul", family: "integer-arithmetic"),
        "%": Swap(replacement: "*", name: "rem-to-mul", family: "integer-arithmetic"),
    ]

    /// Compound assignments, paired the same way.
    ///
    /// A separate row rather than a rewrite of the arithmetic table, because `a += b` and
    /// `a = a + b` are different edits at different spans and a reader looking for one
    /// should find it where they looked.
    static let compoundAssignments: [String: Swap] = [
        "+=": Swap(
            replacement: "-=",
            name: "add-assign-to-sub-assign",
            family: "arithmetic-assignment"
        ),
        "-=": Swap(
            replacement: "+=",
            name: "sub-assign-to-add-assign",
            family: "arithmetic-assignment"
        ),
        "*=": Swap(
            replacement: "/=",
            name: "mul-assign-to-div-assign",
            family: "arithmetic-assignment"
        ),
        "/=": Swap(
            replacement: "*=",
            name: "div-assign-to-mul-assign",
            family: "arithmetic-assignment"
        ),
    ]

    /// Bitwise operators and shifts.
    ///
    /// The same kind of edit on the same kind of expression as arithmetic, so the same
    /// pairing. A shift in the wrong direction is the classic packing bug, and a suite that
    /// round-trips a value without checking it will not see either half.
    static let bitwise: [String: Swap] = [
        "&": Swap(replacement: "|", name: "bitand-to-bitor", family: "bitwise"),
        "|": Swap(replacement: "&", name: "bitor-to-bitand", family: "bitwise"),
        "^": Swap(replacement: "&", name: "xor-to-bitand", family: "bitwise"),
        "<<": Swap(replacement: ">>", name: "shl-to-shr", family: "bitwise"),
        ">>": Swap(replacement: "<<", name: "shr-to-shl", family: "bitwise"),
    ]

    /// Which operand a prune keeps.
    enum Side: Sendable {
        case left
        case right
    }

    /// Dropping one operand of a connective.
    ///
    /// Distinct from a swap in both what it edits and what it detects. A swap replaces the
    /// operator and asks whether the tests notice which connective is there; a prune
    /// replaces the whole expression with one of its operands and asks the blunter
    /// question of whether they notice the other operand at all. `a && b` becoming `a`
    /// survives exactly when nothing in the suite depends on `b`, which is the shape of a
    /// condition that was tightened once, for a bug, and never tested.
    ///
    /// Both sides of both connectives. The family is often written with the two `&&` forms
    /// alone, but `a || b` becoming `b` says "the left operand never mattered" just as
    /// precisely as its mirror does, and there is no argument for detecting one and not
    /// the other.
    struct Prune: Sendable {
        let side: Side
        let name: String
        let family: String
    }

    /// The prunes each connective offers.
    static let connectivePrunes: [String: [Prune]] = [
        "&&": [
            Prune(side: .left, name: "and-keep-lhs", family: "boolean-connective"),
            Prune(side: .right, name: "and-keep-rhs", family: "boolean-connective"),
        ],
        "||": [
            Prune(side: .left, name: "or-keep-lhs", family: "boolean-connective"),
            Prune(side: .right, name: "or-keep-rhs", family: "boolean-connective"),
        ],
    ]

    /// Dropping one clause of a comma-separated condition list.
    ///
    /// The same rule as a connective prune, in the syntax people actually write conditions
    /// in. `guard a, b else` is `guard a && b else`, so "is this clause load-bearing" is
    /// the question ``Prune`` already asks - it just never fired here, because it looks for
    /// the operator and the source has commas.
    ///
    /// Spelled as replacing the clause with `true` rather than as rewriting the list, and
    /// the two are the same program: a list is not an expression, so it cannot be wrapped
    /// in a ternary, while one clause of it can.
    ///
    /// Measured on a real package whose author had written the mutations by hand: clauses
    /// dropped from condition lists were the largest family they had that a tool could
    /// generate, and three of the six holes they closed in one session were a guard clause
    /// that could never fire. A clause that reads as the thing keeping something honest and
    /// is in fact dead is a shape nothing else in this catalogue looks for.
    static let dropCondition = Prune(
        side: .left, name: "drop-condition", family: "boolean-connective")

    /// A conditional made into a no-op.
    ///
    /// The same question as dropping a clause - is this condition load-bearing - asked of a
    /// condition that has only one clause, which is where most of them are.
    ///
    /// The constant depends on the keyword, and that is the whole of the design. A guard's
    /// condition is the case that *continues*, so `true` is the no-op; an `if`'s condition
    /// is the case that *runs*, so `false` is. Generating both constants for both keywords
    /// would generate the uninteresting half of each: `if c` made `true` is not "does this
    /// body ever run", it is "does the else branch matter" - a different and much noisier
    /// question, which a package measured at five useful instances in two hundred and
    /// ninety hand-written mutations.
    ///
    /// Its own family, because it is its own question: a project turning it off should not
    /// lose the operator swaps inside the same conditions.
    static let neverDecides = Prune(
        side: .left, name: "condition-never-decides", family: "condition-decision")

    /// What a guard's condition becomes when it never bails.
    static let guardNoOp = "true"

    /// What an `if`'s condition becomes when its body never runs - and a `while`'s, for
    /// the same reason: both are the case that runs.
    ///
    /// Never the other direction for any keyword. `while true` does not stop, and a mutant
    /// that hangs a suite is answered by the deadline - which would report it as a
    /// detection about this tool rather than about the tests.
    static let ifNoOp = "false"

    /// Every binary operator this tool has a meaning for.
    ///
    /// An operator that is not here is left alone. Swift lets a package define its own, and
    /// swapping one for another would be swapping something for something else at random.
    /// Whether a swap is one that only makes sense between numbers.
    ///
    /// Arithmetic and its compound forms. Comparison is not here - `<` really does work on
    /// strings and arrays, so `"a" <= "b"` is a mutant worth having. Neither are the
    /// connectives or the bitwise operators, which have no literal forms to recognise.
    static func isArithmetic(_ swap: Swap) -> Bool {
        swap.family == "integer-arithmetic" || swap.family == "arithmetic-assignment"
    }

    static let binaryOperators: [String: Swap] = {
        var table = comparisons
        for family in [connectives, arithmetic, compoundAssignments, bitwise] {
            table.merge(family) { first, _ in first }
        }
        return table
    }()

    /// Boolean literals.
    static let booleanLiterals: [String: Swap] = [
        "true": Swap(replacement: "false", name: "true-to-false", family: "boolean-literal"),
        "false": Swap(replacement: "true", name: "false-to-true", family: "boolean-literal"),
    ]

    /// Every family a rule belongs to.
    static let families: Set<String> = [
        "comparison", "boolean-connective", "boolean-literal", "integer-arithmetic",
        "arithmetic-assignment", "bitwise", "condition-decision",
    ]

    /// The identifier for a swap, at the version this build emits.
    ///
    /// The version participates in every identity the rule produces, so changing what a
    /// rule emits invalidates its cached outcomes loudly instead of inheriting verdicts
    /// reached about different bytes.
    static func identifier(for swap: Swap) -> RuleIdentifier {
        Self.identifier(named: swap.name)
    }

    /// The identifier for a prune, at the version this build emits.
    static func identifier(for prune: Prune) -> RuleIdentifier {
        Self.identifier(named: prune.name)
    }

    static func identifier(named name: String) -> RuleIdentifier {
        guard let rule = RuleIdentifier(name, version: 1) else {
            fatalError("'\(name)' is not a well-formed rule name")
        }
        return rule
    }
}
