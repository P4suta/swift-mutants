// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// A boolean literal that is the whole condition of a loop.
///
/// `while true` is not a decision the program makes. It is how Swift spells "loop", the way
/// `for` spells it in other languages, and flipping it does not perturb a predicate - it
/// removes the loop. A suite notices that the way it would notice the body being deleted,
/// which is a mutant this catalogue does not have and would not gain by having twice.
///
/// It is also usually not a program. The compiler knows a `while true` with no `break`
/// never falls out of the bottom, so a function may end with one and return nothing
/// afterwards; `while false` falls out immediately and the function is left with a path
/// that returns nothing. `TOMLParser.array()` in this package is written exactly that way.
///
/// And that error is the expensive kind. `missing return in instance method expected to
/// return '[TOMLValue]'` is reported against the function's closing brace, not against the
/// literal inside it, so it lands nowhere this tool put a mutant - and a run then halves
/// its way through the catalogue for a mutant that could never have compiled.
@Suite("Loop conditions")
struct LoopConditionTests {

    static func found(_ source: String) -> FileDiscovery {
        Discover.candidates(in: source, at: ArithmeticTests.path())
    }

    static func names(_ source: String) -> [String] {
        Self.found(source).candidates.map(\.rule.name)
    }

    @Test(
        "passes over a literal that is the whole condition of a loop",
        arguments: [
            "func f() { while true { break } }",
            "func f() { while false { break } }",
            "func f() { repeat { break } while true }",
        ]
    )
    func passesOverLoopLiterals(_ source: String) {
        #expect(Self.names(source).isEmpty)
    }

    @Test("says so, and says how many it hid")
    func saysSo() {
        let discovery = Self.found("func f() { while true { break } }")
        #expect(discovery.skips.map(\.reason) == [.loopConditionLiteral])
        #expect(discovery.skips.first?.candidatesHidden == 1)
    }

    /// Only the whole condition. `while ready && true` has a decision in it, and the
    /// literal is part of that decision rather than a spelling of "loop".
    @Test("leaves a literal that is part of a condition alone")
    func partOfAConditionIsStillADecision() {
        #expect(
            Self.names("func f(_ ready: Bool) { while ready && true { break } }")
                .contains("true-to-false")
        )
    }

    /// And a literal anywhere else is untouched: this is about loops, not about literals.
    @Test(
        "leaves a literal that is not a loop's condition alone",
        arguments: [
            "func f() -> Bool { true }",
            "func f() { if true { } }",
            "func f() { let ready = true; _ = ready }",
            "func f(_ xs: [Int]) { for x in xs where true { _ = x } }",
        ]
    )
    func otherLiteralsAreUntouched(_ source: String) {
        #expect(Self.names(source) == ["true-to-false"])
    }
}
