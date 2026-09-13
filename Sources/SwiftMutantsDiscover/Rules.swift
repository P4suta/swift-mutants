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

    /// Every binary operator this tool has a meaning for.
    ///
    /// An operator that is not here is left alone. Swift lets a package define its own, and
    /// swapping one for another would be swapping something for something else at random.
    static let binaryOperators: [String: Swap] = comparisons.merging(connectives) { first, _ in
        first
    }

    /// Boolean literals.
    static let booleanLiterals: [String: Swap] = [
        "true": Swap(replacement: "false", name: "true-to-false", family: "boolean-literal"),
        "false": Swap(replacement: "true", name: "false-to-true", family: "boolean-literal"),
    ]

    /// Every family a rule belongs to.
    static let families: Set<String> = ["comparison", "boolean-connective", "boolean-literal"]

    /// The identifier for a swap, at the version this build emits.
    ///
    /// The version participates in every identity the rule produces, so changing what a
    /// rule emits invalidates its cached outcomes loudly instead of inheriting verdicts
    /// reached about different bytes.
    static func identifier(for swap: Swap) -> RuleIdentifier {
        guard let rule = RuleIdentifier(swap.name, version: 1) else {
            fatalError("'\(swap.name)' is not a well-formed rule name")
        }
        return rule
    }
}
