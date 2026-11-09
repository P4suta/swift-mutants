// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore

/// The rules that swap one operator or literal for another.
///
/// A table rather than a chain of conditions, so that the catalogue is a thing a reader can see the whole of, and so that adding a rule is adding a row.
enum Rules {

    /// One swap: what it matches, what it produces, and what it is called.
    struct Swap: Sendable {
        let replacement: String
        let name: String
        let family: String
    }

    /// Which operand a prune keeps.
    enum Side: Sendable {
        case left
        case right
    }

    /// Dropping one operand of a connective.
    ///
    /// Distinct from a swap in both what it edits and what it detects.
    /// A swap replaces the operator and asks whether the tests notice which connective is there; a prune replaces the whole expression with one of its operands and asks the blunter question of whether they notice the other operand at all.
    /// `a && b` becoming `a` survives exactly when nothing in the suite depends on `b`, which is the shape of a condition that was tightened once, for a bug, and never tested.
    ///
    /// Both sides of both connectives.
    /// The family is often written with the two `&&` forms alone, but `a || b` becoming `b` says "the left operand never mattered" just as precisely as its mirror does, and there is no argument for detecting one and not the other.
    struct Prune: Sendable {
        let side: Side
        let name: String
        let family: String
    }

    /// The prunes each connective offers.
    /// A pattern's extra condition, made always or never to hold.
    ///
    /// A `where` clause is a condition nobody looks at twice: it sits beside a pattern that already reads as the interesting part, and a suite that covers the pattern usually says nothing about the clause.
    /// Always matching asks whether the clause is load-bearing; never matching asks whether anything reaches the case at all.
    ///
    /// Safe on a `switch`, which is the case worth worrying about: Swift does not count a `where`-guarded case towards exhaustiveness, so a clause made `false` cannot turn an exhaustive switch into one the compiler refuses.
    /// Measured, not assumed.
    static let patternAlwaysMatches = Swap(
        replacement: "true", name: "pattern-always-matches", family: "pattern-matching")

    static let patternNeverMatches = Swap(
        replacement: "false", name: "pattern-never-matches", family: "pattern-matching")

    /// An optional `try` that fails every time.
    ///
    /// `try?` is the one line in a program whose whole purpose is that a failure stops being a failure, which makes "does anything test the path this was written for" the only question worth asking about it.
    ///
    /// It keeps the type by construction: `try? f()` and `nil` are both the optional the expression already was.
    /// A plain `try` is not offered - it propagates rather than swallowing, so there is nothing there to turn into nothing.
    static let tryOptionalFails = Prune(
        side: .left, name: "try-optional-fails", family: "error-handling")

    /// A statement that does not run.
    ///
    /// The largest family there is by volume, and the one with the best record.
    /// Google's measurement over six years of a two-billion-line monorepo put statement deletion at 68% of all mutants generated and around 80% productivity - the highest of any operator they kept, which is why it is in `balanced` rather than above it.
    ///
    /// It asks the plainest question in mutation testing: if this line never ran, would anything notice?
    /// Most of the time something does, and the times it does not are the lines nobody is testing.
    ///
    /// Two rules rather than one, because a call and an assignment are different things to a reader looking at a report: one is work that was never done, the other a value that was never written.
    static let skipCall = Prune(
        side: .left, name: "skip-call", family: "statement-deletion")

    static let skipAssignment = Prune(
        side: .left, name: "skip-assignment", family: "statement-deletion")

    /// Dropping one clause of a comma-separated condition list.
    ///
    /// The same rule as a connective prune, in the syntax people actually write conditions in.
    /// `guard a, b else` is `guard a && b else`, so "is this clause load-bearing" is the question ``Prune`` already asks - it just never fired here, because it looks for the operator and the source has commas.
    ///
    /// Spelled as replacing the clause with `true` rather than as rewriting the list, and the two are the same program: a list is not an expression, so it cannot be wrapped in a ternary, while one clause of it can.
    ///
    /// Measured on a real package whose author had written the mutations by hand: clauses dropped from condition lists were the largest family they had that a tool could generate, and three of the six holes they closed in one session were a guard clause that could never fire.
    /// A clause that reads as the thing keeping something honest and is in fact dead is a shape nothing else in this catalogue looks for.
    static let dropCondition = Prune(
        side: .left, name: "drop-condition", family: "boolean-connective")

    /// A conditional made into a no-op.
    ///
    /// The same question as dropping a clause - is this condition load-bearing - asked of a condition that has only one clause, which is where most of them are.
    ///
    /// The constant depends on the keyword, and that is the whole of the design.
    /// A guard's condition is the case that *continues*, so `true` is the no-op; an `if`'s condition is the case that *runs*, so `false` is.
    /// Generating both constants for both keywords would generate the uninteresting half of each: `if c` made `true` is not "does this body ever run", it is "does the else branch matter" - a different and much noisier question, which a package measured at five useful instances in two hundred and ninety hand-written mutations.
    ///
    /// Its own family, because it is its own question: a project turning it off should not lose the operator swaps inside the same conditions.
    static let neverDecides = Prune(
        side: .left, name: "condition-never-decides", family: "condition-decision")

    /// A concatenation with its operands the other way round.
    ///
    /// `+` on something syntax alone can tell is not a number was passed over entirely:
    /// `add-to-sub` on it would not compile, so the tool recorded a `non-numeric-operand` skip and moved on.
    /// That left the lines where mutation testing is worth most - domain separation, key derivation, authenticated associated data - contributing nothing at all.
    ///
    /// Reported from a package doing exactly that, about `[suite.rawValue] + account.bytes + operation.bytes`: swapping those operands makes a frame movable between accounts, and their suite catches it.
    /// A score that says nothing about the line cannot say they caught it.
    ///
    /// The cheapest mutation here to be confident about.
    /// Both sides keep their types, so it compiles wherever the original did; concatenation does not commute, so it changes the program wherever the operands differ - and where they do not, it is not offered.
    ///
    /// Its own family, because a project turning it off is making a different decision from one turning off arithmetic.
    static let concatSwap = Prune(
        side: .left, name: "concat-swap", family: "concatenation")

    /// What a guard's condition becomes when it never bails.
    static let guardNoOp = "true"

    /// What an `if`'s condition becomes when its body never runs - and a `while`'s, for the same reason: both are the case that runs.
    ///
    /// Never the other direction for any keyword.
    /// `while true` does not stop, and a mutant that hangs a suite is answered by the deadline - which would report it as a detection about this tool rather than about the tests.
    static let ifNoOp = "false"

    /// Whether an operator swap requires numeric operands.
    static func isArithmetic(_ swap: Swap) -> Bool {
        swap.family == "integer-arithmetic"
    }

    /// Which family each rule belongs to, by the name a catalogue prints.
    ///
    /// Derived from the discovery tables for family selection and source suppressions.
    static let familyOfRule: [String: String] = {
        var table: [String: String] = [:]
        // Named by what they become, so every partner of every pair is a rule of its own.
        for swap in binaryOperators.values { table[swap.name] = swap.family }
        for swap in booleanLiterals.values { table[swap.name] = swap.family }
        for swap in [patternAlwaysMatches, patternNeverMatches] {
            table[swap.name] = swap.family
        }
        for prunes in connectivePrunes.values {
            for prune in prunes { table[prune.name] = prune.family }
        }
        for prune in [
            dropCondition, neverDecides, concatSwap,
            skipCall, skipAssignment,
            tryOptionalFails,
        ] {
            table[prune.name] = prune.family
        }
        return table
    }()

    /// Every family a rule belongs to.
    ///
    /// Read off the rules rather than listed again beside them.
    /// Written out by hand, it was missing `concatenation` - so a project that wrote `// swift-mutants disable concatenation` was told their own family was a typo, and the comment they believed had dealt with a mutant silenced nothing.
    /// A list of names kept in step with another list of names by somebody remembering to is a list that is wrong between the two commits nobody made.
    static let families: Set<String> = Set(Self.familyOfRule.values)

    /// The identifier for a swap, at the version this build emits.
    ///
    /// The version participates in every identity the rule produces, so changing what a rule emits invalidates its cached outcomes loudly instead of inheriting verdicts reached about different bytes.
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
