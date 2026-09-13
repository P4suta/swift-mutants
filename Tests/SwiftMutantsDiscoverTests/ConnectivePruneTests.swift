// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// Dropping one side of `&&` or `||`.
///
/// A swap asks whether the tests notice which connective is there. A prune asks a blunter
/// question: whether they notice one of the operands at all. `a && b` becoming `a` survives
/// exactly when nothing in the suite depends on `b` - which is the shape of a condition
/// that was tightened once, for a bug, and never tested.
///
/// Both sides of both connectives, rather than the two forms the family is usually written
/// with. `a || b` becoming `b` says "the left operand never mattered" just as precisely as
/// its mirror does, and there is no argument for detecting one and not the other.
@Suite("Connective prunes")
struct ConnectivePruneTests {

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func rules(_ source: String) -> [String] {
        Discover.candidates(in: source, at: Self.path()).candidates
            .map(\.rule.name).sorted()
    }

    @Test("drops either side of a conjunction")
    func conjunction() {
        #expect(
            Self.rules("func f(_ a: Bool, _ b: Bool) -> Bool { a && b }")
                == ["and-keep-lhs", "and-keep-rhs", "and-to-or"]
        )
    }

    @Test("drops either side of a disjunction")
    func disjunction() {
        #expect(
            Self.rules("func f(_ a: Bool, _ b: Bool) -> Bool { a || b }")
                == ["or-keep-lhs", "or-keep-rhs", "or-to-and"]
        )
    }

    @Test("replaces the whole expression, not the operator")
    func replacesTheWholeExpression() throws {
        let found = Discover.candidates(
            in: "func f(_ a: Bool, _ b: Bool) -> Bool { a && b }",
            at: Self.path()
        )
        let prune = try #require(found.candidates.first { $0.rule.name == "and-keep-lhs" })
        #expect(prune.original == "a && b")
        #expect(prune.replacement == "a")
        // The edit and the guard cover the same bytes: there is no smaller expression to
        // wrap when the replacement *is* one of the operands.
        #expect(prune.span == prune.guardSpan)
    }

    /// Folding is what makes this correct. SwiftSyntax hands back `a && b || c` as one flat
    /// sequence with no grouping at all, so a tool that worked on the raw tree would have to
    /// guess which operands belong to which connective - and would get the precedence wrong
    /// in exactly the cases that matter.
    @Test("takes the operands precedence actually gives each connective")
    func respectsPrecedence() {
        let found = Discover.candidates(
            in: "func f(_ a: Bool, _ b: Bool, _ c: Bool) -> Bool { a && b || c }",
            at: Self.path()
        )
        let replacements = Set(
            found.candidates
                .filter {
                    $0.rule.name.hasSuffix("-keep-lhs") || $0.rule.name.hasSuffix("-keep-rhs")
                }
                .map(\.replacement)
        )
        #expect(replacements == ["a && b", "c", "a", "b"])
    }

    @Test("keeps a comparison whole when it is an operand")
    func comparisonOperands() {
        let found = Discover.candidates(
            in: "func f(_ a: Int, _ b: Int) -> Bool { a < b && a > b }",
            at: Self.path()
        )
        let prunes = found.candidates.filter { $0.rule.name.contains("-keep-") }
        #expect(prunes.map(\.replacement).sorted() == ["a < b", "a > b"])
    }

    /// An operand the tool cannot flatten onto one line is the instrumenter's problem, not
    /// discovery's - but discovery must not be the thing that loses it silently.
    @Test("offers a prune even across lines")
    func multiLineOperands() {
        #expect(
            Self.rules(
                """
                func f(_ a: Bool, _ b: Bool) -> Bool {
                    a
                        && b
                }
                """
            ) == ["and-keep-lhs", "and-keep-rhs", "and-to-or"]
        )
    }

    /// The comment escape hatch names families, and a prune is in the same family as the
    /// swap it sits beside, so one comment silences the site rather than half of it.
    @Test("obeys the same comment that silences the swap")
    func obeysSuppression() {
        #expect(
            Self.rules(
                """
                func f(_ a: Bool, _ b: Bool) -> Bool {
                    // swift-mutants disable next-line boolean-connective: covered elsewhere
                    return a && b
                }
                """
            ).isEmpty
        )
    }
}
