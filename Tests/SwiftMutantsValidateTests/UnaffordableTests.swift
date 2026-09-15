// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsValidate

/// Telling "this is not valid Swift" from "this is valid and too expensive to check".
///
/// Two diagnostics, two different things for somebody to do. A mutant the compiler refuses
/// is a fact about the mutant, and there is nothing to act on: the tool drops it and moves
/// on. An expression the compiler cannot afford to type-check is a fact about *their* code
/// - it type-checks fine as written and tips over once guards wrap its subexpressions, so
/// it was already close to the edge - and breaking it into statements is usually an
/// improvement they would have wanted anyway.
///
/// Reported from a real package twice in three runs, both times a genuine finding about the
/// package, and both times it arrived looking exactly like a mutant that was not valid
/// Swift.
///
/// It also costs differently, which is the part that decides how a run behaves. Looking for
/// an invalid mutant, every compile fails fast. Looking for an unaffordable one, every
/// compile pays the whole type-checking budget before giving up. Measured on that package:
/// seven and a half minutes of halving on a package that builds in forty seconds.
@Suite("Refused, or unaffordable")
struct UnaffordableTests {

    static func diagnostic(_ message: String) throws -> CompilerDiagnostic {
        try #require(CompilerDiagnostic.parse("/tmp/a.swift:1:1: error: \(message)").first)
    }

    @Test(
        "knows the compiler running out of budget",
        arguments: [
            "the compiler is unable to type-check this expression in reasonable time; "
                + "try breaking up the expression into distinct sub-expressions",
            "unable to type-check this expression in reasonable time",
        ])
    func knowsUnaffordable(_ message: String) throws {
        #expect(try Self.diagnostic(message).isUnaffordable)
    }

    @Test(
        "knows an ordinary refusal from one",
        arguments: [
            "binary operator '-' cannot be applied to two 'String' operands",
            "missing return in a function expected to return 'Bool'",
            "cannot convert value of type 'String' to expected argument type 'Int'",
            "expression is too complex to be used as a statement",
        ])
    func knowsRefusals(_ message: String) throws {
        #expect(try !Self.diagnostic(message).isUnaffordable)
    }

    /// A warning that says the same thing is still a warning: it does not stop a build, so
    /// it is not why a compile failed.
    @Test("says nothing about a warning")
    func warningsAreNotRefusals() throws {
        let parsed = CompilerDiagnostic.parse(
            "/tmp/a.swift:1:1: warning: the compiler is unable to type-check this expression "
                + "in reasonable time")
        #expect(try #require(parsed.first).isUnaffordable == false)
    }
}
