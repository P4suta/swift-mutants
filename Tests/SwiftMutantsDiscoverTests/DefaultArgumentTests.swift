// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// Mutants inside a default argument value.
///
/// These were passed over, and the reason was true when it was written: Swift refuses a
/// default argument value that references a `private` declaration, and the runtime this tool
/// appends was private. A guard there produced a complaint about the guard rather than about
/// the mutant, which lands nowhere attribution can place it - and a run then halved its way
/// through the whole catalogue looking for a mutant that could never have compiled.
///
/// The runtime stopped being private for a different reason. Swift will not let an
/// `@inlinable` function reference a private symbol either, so a package with inlinable
/// inner loops had every mutant in them refused; the fix was to make the runtime
/// `@usableFromInline internal`, visible to the module rather than to the file.
///
/// That fixed this as a side effect and nobody noticed. A default argument value may
/// reference a `@usableFromInline` declaration - measured directly on this toolchain, in a
/// public function, in an `@inlinable` one, in an initialiser, and under library evolution,
/// which is the strictest of the four.
///
/// So the rule went. It was passing over 133 places on this repository to hide six mutants,
/// and both numbers were pure loss: the mutants because they compile, and the places because
/// every one of them was a line in `why-skipped` about nothing.
@Suite("A default argument value")
struct DefaultArgumentTests {

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func found(_ body: String) -> FileDiscovery {
        Discover.candidates(in: body, at: Self.path())
    }

    /// A boolean literal, which the default profile does mutate wherever it is. The first
    /// version of this used bare integer literals, which it does not: `int-literal-to-zero`
    /// is in `all` rather than in `balanced`, so the test would have been asserting
    /// something about the profile rather than about default arguments.
    @Test("is mutated like anything else")
    func isMutated() {
        let found = Self.found("func page(wide: Bool = true) -> Bool { wide }")
        #expect(
            found.candidates.contains { $0.rule.name == "true-to-false" },
            "\(found.candidates.map(\.rule.name))")
    }

    /// A comparison in a default argument is an expression like any other.
    @Test("is mutated when the default is an expression rather than a literal")
    func expressionDefault() {
        let found = Self.found(
            "func page(_ a: Int, _ b: Int, wide: Bool = 80 < 100) -> Bool { wide }")
        #expect(
            found.candidates.contains { $0.rule.name == "lt-to-le" },
            "\(found.candidates.map(\.rule.name))")
    }

    /// And the rule that hid them is gone rather than narrowed, so nothing says a place was
    /// passed over when it was not.
    @Test("is not passed over any more")
    func noSkip() {
        let found = Self.found("func page(limit: Int = 10) -> Int { limit }")
        #expect(!found.skips.contains { $0.reason.rawValue == "default-argument" })
    }
}
