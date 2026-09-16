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
    /// A statement that does not run.
    ///
    /// The largest family there is by volume, and the one with the best record. Google's
    /// measurement over six years of a two-billion-line monorepo put statement deletion at
    /// 68% of all mutants generated and around 80% productivity - the highest of any
    /// operator they kept, which is why it is in `balanced` rather than above it.
    ///
    /// It asks the plainest question in mutation testing: if this line never ran, would
    /// anything notice? Most of the time something does, and the times it does not are the
    /// lines nobody is testing.
    ///
    /// Two rules rather than one, because a call and an assignment are different things to
    /// a reader looking at a report: one is work that was never done, the other a value
    /// that was never written.
    static let skipCall = Prune(
        side: .left, name: "skip-call", family: "statement-deletion")

    static let skipAssignment = Prune(
        side: .left, name: "skip-assignment", family: "statement-deletion")

    /// One end of a collection named as the other.
    ///
    /// Its own family because a project turning it off is making a different decision from
    /// one turning off arithmetic: these are about *which end*, and a package that does no
    /// sequence work gets nothing from them.
    static func endSwap(to name: String) -> Swap {
        Swap(
            replacement: name,
            name: CollectionEnds.ruleName(for: name),
            family: "collection-boundary")
    }

    /// A range that reaches one element further than it was written to.
    ///
    /// The fencepost, written down. `a..<b` made `a..<(b + 1)` includes the element the
    /// author decided to leave out, and on an index that is a trap rather than a wrong
    /// answer - which is a kill, and a fast one.
    ///
    /// **Not** `..<` swapped for `...`, which was the obvious rule and does not work. The
    /// two operators build *different types* - `Range` and `ClosedRange` - and a ternary
    /// guard needs its branches to unify, so every one of those mutants was refused by the
    /// compiler. Found by a compile gate, and the reason this family looks the way it does:
    /// shifting the bound keeps the type by construction.
    ///
    /// The upper bound rather than the lower, because that is where fencepost bugs live:
    /// the start of a range is nearly always a constant somebody typed once.
    static let widenRange = Prune(
        side: .right, name: "range-one-further", family: "range-operator")

    /// What a program does when there is nothing.
    ///
    /// `a ?? b` made to reach for `b` every time asks whether anything ever tests the
    /// *present* case. Made to insist on `a`, it asks whether anything tests the absent one
    /// - and traps where nothing does, which is a kill rather than a wrong answer.
    ///
    /// Two different holes, and most suites have exactly one of them.
    ///
    /// The default side is a prune, because `b` is already the type the whole expression
    /// has. The value side cannot be: `a` is the *optional*, so keeping it on its own is a
    /// type error wherever the result is used, and this rule would have generated nothing
    /// but rejections. It is written as a force unwrap instead, which has the right type by
    /// construction.
    static let coalesceToDefault = Prune(
        side: .right, name: "coalesce-to-default", family: "optional-handling")

    static let coalesceToForce = Prune(
        side: .left, name: "coalesce-to-force", family: "optional-handling")

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

    /// A declaration's body replaced by a constant.
    ///
    /// The only rule here that is about a declaration rather than an operator, and it asks
    /// the sharpest question in the catalogue: does anything notice when this stops doing
    /// anything at all? A survivor is a *pseudo-tested* declaration - covered by tests that
    /// assert nothing whatever about it - which is a median of one method in ten across
    /// every project the literature surveys.
    ///
    /// Almost no equivalent mutants, because a body that can be replaced by a constant with
    /// nothing noticing is a finding whichever constant was chosen.
    ///
    /// Its own family, and in no tier: it is off unless a run asks for it, because it
    /// multiplies the catalogue by the number of declarations rather than by the number of
    /// operators, and that is a decision about how long a run takes.
    static let replaceBody = Prune(
        side: .left, name: "replace-body", family: "body-replacement")

    /// A body that stops doing its work.
    ///
    /// The statement-guarded half of body replacement, for the two shapes a ternary cannot
    /// reach: a body of several statements, which is not an expression, and a body that
    /// returns nothing, which has no value to put in a ternary's branches.
    ///
    /// The second is the better mutant of the two and had no way to exist until now. "Does
    /// anything notice when this function stops doing its work" is the sharpest question
    /// that can be asked about a procedure, and a procedure is most of what most packages
    /// are made of.
    static let stopBody = Prune(
        side: .left, name: "stop-body", family: "body-replacement")

    /// A concatenation with its operands the other way round.
    ///
    /// `+` on something syntax alone can tell is not a number was passed over entirely:
    /// `add-to-sub` on it would not compile, so the tool recorded a `non-numeric-operand`
    /// skip and moved on. That left the lines where mutation testing is worth most -
    /// domain separation, key derivation, authenticated associated data - contributing
    /// nothing at all.
    ///
    /// Reported from a package doing exactly that, about
    /// `[suite.rawValue] + account.bytes + operation.bytes`: swapping those operands makes
    /// a frame movable between accounts, and their suite catches it. A score that says
    /// nothing about the line cannot say they caught it.
    ///
    /// The cheapest mutation here to be confident about. Both sides keep their types, so it
    /// compiles wherever the original did; concatenation does not commute, so it changes
    /// the program wherever the operands differ - and where they do not, it is not offered.
    ///
    /// Its own family, because a project turning it off is making a different decision from
    /// one turning off arithmetic.
    static let concatSwap = Prune(
        side: .left, name: "concat-swap", family: "concatenation")

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

    /// Which family each rule belongs to, by the name a catalogue prints.
    ///
    /// Built from the same tables the walk uses rather than listed again beside them. A
    /// rule added to a table is a rule this knows the family of, which is what keeps a new
    /// operator from being narrowed away by a `profile` that has never heard of it.
    static let familyOfRule: [String: String] = {
        var table: [String: String] = [:]
        // Named by what they become, so every partner of every pair is a rule of its own.
        for name in CollectionEnds.everyName {
            table[CollectionEnds.ruleName(for: name)] = "collection-boundary"
        }
        for swap in binaryOperators.values { table[swap.name] = swap.family }
        for swap in booleanLiterals.values { table[swap.name] = swap.family }
        for prunes in connectivePrunes.values {
            for prune in prunes { table[prune.name] = prune.family }
        }
        for prune in [
            dropCondition, neverDecides, concatSwap, replaceBody, stopBody,
            coalesceToDefault, coalesceToForce, widenRange, skipCall, skipAssignment,
        ] {
            table[prune.name] = prune.family
        }
        return table
    }()

    /// Every family a rule belongs to.
    static let families: Set<String> = [
        "comparison", "boolean-connective", "boolean-literal", "integer-arithmetic",
        "arithmetic-assignment", "bitwise", "condition-decision", "body-replacement",
        "range-operator", "optional-handling", "collection-boundary", "statement-deletion",
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
