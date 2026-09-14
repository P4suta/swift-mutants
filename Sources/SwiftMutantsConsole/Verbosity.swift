// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// How much a run says.
///
/// Three audiences with three different needs, and one flag each. Somebody running this in
/// a script wants the exit code and nothing else. Somebody watching it wants to know it has
/// not hung. Somebody working out why it did something wants the account of what it ran.
///
/// Additive: each level says everything the level below it does, and more. A level that
/// swapped one kind of line for another would make `-v` a different report rather than a
/// longer one, and nobody could hold that in their head.
public enum Verbosity: Int, Sendable, Comparable, CaseIterable {

    /// Errors only, and the exit code.
    case quiet

    /// Phases, results and the closing summary.
    case normal

    /// Adds phase durations, what killed each mutant, and what covers a survivor.
    case verbose

    /// Adds one line per recorded event: what the run actually started, as it happens.
    case veryVerbose

    /// Orders by how much is said.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
