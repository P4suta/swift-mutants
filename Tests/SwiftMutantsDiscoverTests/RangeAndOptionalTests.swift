// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// The two operator families Swift has that other languages do not.
///
/// A range and a coalescing operator are where Swift puts the two mistakes every language
/// makes: the off-by-one, and the decision about what to do when there is nothing. Both are
/// one token wide, both are easy to write the other way round, and neither is reachable by
/// any rule written for C.
@Suite("Ranges and optionals")
struct RangeAndOptionalTests {

    static func rules(_ source: String) -> [String] {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        return Discover.candidates(in: source, at: path, selecting: mutation)
            .candidates.map(\.rule.name).sorted()
    }

    static func replacements(_ source: String, for rule: String) -> [String] {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        return Discover.candidates(in: source, at: path, selecting: mutation)
            .candidates.filter { $0.rule.name == rule }.map(\.replacement)
    }

    /// The fencepost, written down. A range that reaches one element further than its
    /// author decided includes exactly the element every off-by-one is about - and on an
    /// index it traps, which is a kill rather than a wrong answer.
    @Test("makes a half-open range reach one further")
    func halfOpenOneFurther() {
        #expect(
            Self.replacements("let s = xs[0..<n]", for: "range-one-further")
                == ["0 ..< ((n) + 1)"])
    }

    @Test("makes a closed range reach one further")
    func closedOneFurther() {
        #expect(
            Self.replacements("let s = xs[0...n]", for: "range-one-further")
                == ["0 ... ((n) + 1)"])
    }

    /// Never the operator swapped for the other one. `..<` and `...` build *different
    /// types* - `Range` and `ClosedRange` - and a ternary guard needs its branches to
    /// unify, so every one of those mutants is refused by the compiler. Shifting the bound
    /// keeps the type by construction.
    @Test("never swaps one range operator for the other")
    func neverSwapsTheOperator() {
        let found = Self.rules("let s = xs[0..<n]") + Self.rules("let s = xs[0...n]")
        #expect(!found.contains("half-open-to-closed"), "\(found)")
        #expect(!found.contains("closed-to-half-open"), "\(found)")
    }

    /// A one-sided range is a different operator - prefix or postfix, not infix - and has
    /// no bound on the missing side to shift.
    @Test("leaves a one-sided range alone")
    func oneSided() {
        #expect(!Self.rules("let s = xs[2...]").contains("range-one-further"))
        #expect(!Self.rules("let s = xs[...2]").contains("range-one-further"))
    }

    /// A bound that is visibly not a number has no `+ 1`, and a mutant no compiler accepts
    /// costs a build and reports a rejection.
    @Test("passes over a range whose bound is visibly not a number")
    func notANumber() {
        #expect(!Self.rules(#"let s = "a"..<"z""#).contains("range-one-further"))
    }

    /// What a program does when there is nothing. Reaching for `b` every time asks whether
    /// anything ever tests the present case; insisting on `a` asks whether anything tests
    /// the absent one, and traps where nothing does.
    @Test("offers both of a coalescing operator's mutants")
    func coalescing() {
        let found = Self.rules("let v = a ?? b")
        #expect(found.contains("coalesce-to-force"), "\(found)")
        #expect(found.contains("coalesce-to-default"), "\(found)")
    }

    /// The asymmetry is the point, and it is about types. `b` is already what the whole
    /// expression is; `a` is the optional, so keeping it alone is a type error wherever the
    /// result is used - a rule that did that would have generated nothing but rejections.
    @Test("writes the value side as a force unwrap rather than as the operand")
    func coalescingOperands() {
        #expect(Self.replacements("let v = a ?? b", for: "coalesce-to-default") == ["b"])
        #expect(Self.replacements("let v = a ?? b", for: "coalesce-to-force") == ["(a)!"])
    }

    /// Both families are in `strong` rather than `balanced`: they are sharp where they
    /// apply and silent everywhere else, which is the shape of a tier above the default.
    @Test("is in the tier that says it is")
    func tiers() {
        for family in ["range-operator", "optional-handling"] {
            #expect(
                RuleSelection.everyFamily.contains(family),
                "\(family) is in no tier, so nothing would ever select it")
        }
    }
}
