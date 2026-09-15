// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsReport
import Testing

@testable import SwiftMutantsCLI

/// What a refusal is somebody's to fix, and when it is nobody's.
///
/// A refused mutant is almost always a fact about the program: the compiler would not
/// accept that edit there, and there is nothing to do. The exception is a mutant the
/// project wrote itself, where the refusal is about a row in their configuration - and
/// where the usual cause has one answer they cannot guess.
@Suite("Explaining a refusal")
struct RefusalAdviceTests {

    static func lines(rule: String) -> String {
        Explanation.of(
            ExplanationTests.mutant(outcome: "rejected", rule: rule),
            reachedBy: []
        ).joined(separator: "\n")
    }

    /// A guard is a ternary, so what a row matched has to be an expression. `let x = f()`
    /// is a declaration, and no form of guard could replace one - wrapping it binds the
    /// name inside a scope that ends at the brace. Anchoring on the initialiser works, and
    /// nobody would work that out from `expected expression in list of expressions`.
    @Test("tells a project what to anchor on when its own mutant was refused")
    func adviceForACustomRow() {
        let said = Self.lines(rule: "custom@1")
        #expect(said.contains("would not accept this change"), "\(said)")
        #expect(said.contains("has to be an expression"), "\(said)")
        #expect(said.contains("Anchor on the initialiser"), "\(said)")
    }

    /// A refusal of an ordinary mutant is a fact about their program, not a task. Advice
    /// there would be advice about a row nobody wrote.
    @Test("says nothing extra when the tool's own mutant was refused")
    func noAdviceForAnOrdinaryRule() {
        let said = Self.lines(rule: "lt-to-le@1")
        #expect(said.contains("would not accept this change"), "\(said)")
        #expect(!said.contains("has to be an expression"), "\(said)")
    }
}
