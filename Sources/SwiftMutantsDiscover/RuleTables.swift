// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// The rules the walk looks a token up in.
///
/// Apart from the rules it names directly, because these are a lookup and those are a
/// decision: a walk that has an operator token in hand asks this what the token becomes,
/// and a walk that has recognised a shape - a body it can stop, a clause it can drop -
/// names the rule itself. Keeping the two apart is what lets a new operator be a line in a
/// table rather than a line in a visit.
extension Rules {

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
}
