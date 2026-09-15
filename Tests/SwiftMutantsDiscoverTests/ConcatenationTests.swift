// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// A concatenation with its operands the other way round.
///
/// `+` on something that is visibly not a number was passed over entirely: `add-to-sub` on
/// it would not compile, so the tool recorded a `non-numeric-operand` skip and moved on.
/// That left the lines where it matters most contributing nothing.
///
/// Reported from a package doing key derivation and authenticated encryption, about lines
/// like these:
///
/// ```swift
/// public var bytes: [UInt8] { [suite.rawValue] + account.bytes + operation.bytes }
/// let info = Array("app/v1/slot/".utf8) + Array(kind.rawValue.utf8) + [0x2F] + id.bytes
/// ```
///
/// Those are the associated data two AEAD layers authenticate and a key-derivation info
/// string. Swapping the operands of either is a real bug - a frame becomes movable between
/// accounts - and it is a bug their suites catch, which is exactly why the score should
/// reflect that they do.
///
/// It is also the cheapest mutation in the catalogue to be confident about: both sides keep
/// their types, so it compiles wherever the original did, and concatenation is not
/// commutative, so it changes the program wherever the operands differ.
@Suite("Concatenation")
struct ConcatenationTests {

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func found(_ body: String) -> [Candidate] {
        Discover.candidates(in: body, at: Self.path()).candidates
    }

    @Test("turns a byte-string concatenation round")
    func swapsOperands() {
        let found = Self.found(
            "func f(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { [0x01] + a + b }")
        let swaps = found.filter { $0.rule.name == "concat-swap" }
        #expect(!swaps.isEmpty, "\(found.map(\.rule.name))")
        // The outermost first, because it carries the largest expression: `([0x01] + a) + b`
        // becomes `b + ([0x01] + a)`, which moves the whole prefix behind the suffix.
        #expect(swaps.contains { $0.replacement.contains("b") }, "\(swaps.map(\.replacement))")
    }

    @Test("leaves the skip in place, because the arithmetic swap is still impossible")
    func stillSkipsTheArithmetic() {
        let discovery = Discover.candidates(
            in: "func f(_ a: [UInt8]) -> [UInt8] { [0x01] + a }", at: Self.path())
        #expect(discovery.skips.contains { $0.reason == .nonNumericOperand })
        #expect(!discovery.candidates.contains { $0.rule.name == "add-to-sub" })
    }

    /// Numbers commute, so swapping them changes nothing any test could see. A mutation
    /// nothing can kill is a mutation that only drags a score down.
    @Test("leaves arithmetic alone")
    func notForNumbers() {
        let found = Self.found("func f(_ a: Int, _ b: Int) -> Int { a + b }")
        #expect(!found.contains { $0.rule.name == "concat-swap" }, "\(found.map(\.rule.name))")
    }

    /// Only `+`, and the subject has to be one the tool can already see is not arithmetic -
    /// otherwise this passes because nothing was offered rather than because `+` was
    /// required. The first version of this test used `(…).count - 1`, where the operands
    /// are a member access and an integer literal: not visibly non-numeric, so no swap
    /// would have been offered however the rule was written. Perturbing the rule to fire
    /// for every operator left it green, which is what a tautology looks like from inside.
    @Test("is only for the operator that concatenates")
    func onlyForPlus() {
        let found = Self.found(#"func f(_ a: [String]) -> [String] { ["x"] - a }"#)
        #expect(!found.contains { $0.rule.name == "concat-swap" }, "\(found.map(\.rule.name))")
    }

    /// `x + x` is the same program whichever way round it is written, and a mutant nothing
    /// can kill is one that only drags a score down.
    ///
    /// Written with literals for the same reason as above: `a + a` is not visibly
    /// non-numeric, so it was never a candidate and the test asserted nothing.
    @Test("does not offer a swap of something with itself")
    func notWhenTheOperandsAreTheSame() {
        let found = Self.found(#"func f() -> [String] { ["x"] + ["x"] }"#)
        #expect(!found.contains { $0.rule.name == "concat-swap" }, "\(found.map(\.rule.name))")
    }
}
