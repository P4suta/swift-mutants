// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// Asking whether a conditional ever does anything.
///
/// The same question as dropping a clause from a list, asked of a condition that has only
/// one clause - which is where most of them are. Make the conditional a no-op and see
/// whether anything notices: `guard c else { bail }` that never bails, `if c { work }` that
/// never works.
///
/// **The constant depends on the keyword**, and that is the whole of the design. A guard's
/// condition is the case that *continues*, so `true` is the no-op; an `if`'s condition is
/// the case that *runs*, so `false` is. Generating both constants for both keywords would
/// be generating the uninteresting half of each: `if c` made `true` is not "does this body
/// ever run", it is "does the else branch matter", which is a different and much noisier
/// question.
///
/// Measured on a real package by somebody who had written the mutations by hand. Of their
/// thirty-one conditions replaced by a constant: sixteen `guard c` to `guard true`, ten
/// `if c` to `if false`, and five `guard c` to `guard false`. The first two are this. The
/// third is a different family - force the other branch - which earns its keep only where
/// the else branch does real work, and is noise where it is a bare `return nil`.
@Suite("Making a conditional a no-op")
struct WholeConditionTests {

    static func candidates(_ source: String) -> [Candidate] {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return Discover.candidates(in: source, at: path).candidates
    }

    static func noOps(_ source: String) -> [Candidate] {
        Self.candidates(source).filter { $0.rule.name == "condition-never-decides" }
    }

    /// A guard's condition is the case that continues, so `true` is the no-op.
    @Test("makes a guard never bail")
    func guardNeverBails() throws {
        let found = Self.noOps(
            """
            func f(_ index: Int, _ count: Int) -> Int {
                guard index + 1 < count else { return 0 }
                return index
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.original == "index + 1 < count")
        #expect(found.first?.replacement == "true")
    }

    /// An `if`'s condition is the case that runs, so `false` is.
    @Test("makes an if never run")
    func ifNeverRuns() throws {
        let found = Self.noOps(
            """
            func f(_ value: Double) -> Double {
                if value.isNaN { return 0 }
                return value
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.original == "value.isNaN")
        #expect(found.first?.replacement == "false")
    }

    /// Both keywords, and each gets only the constant that makes it a no-op. The other
    /// constant asks "does the else branch matter", which is a different and noisier
    /// question and not this family.
    @Test("gives each keyword only the constant that is a no-op")
    func oneConstantEach() {
        #expect(
            Self.noOps("func f(_ a: Bool) -> Int { guard a else { return 0 }; return 1 }")
                .map(\.replacement) == ["true"])
        #expect(
            Self.noOps("func f(_ a: Bool) -> Int { if a { return 0 }; return 1 }")
                .map(\.replacement) == ["false"])
    }

    /// A list of clauses is the other family's question, asked of each clause. Doing both
    /// here would ask the same thing twice and count it twice in the score.
    @Test("leaves a list of clauses to the family that drops clauses")
    func listsAreTheOtherFamily() {
        #expect(Self.noOps("func f(_ a: Bool, _ b: Bool) { if a, b { print(1) } }").isEmpty)
        #expect(
            Self.noOps(
                """
                func f(_ a: Bool, _ b: Bool) -> Int {
                    guard a, b else { return 0 }
                    return 1
                }
                """
            ).isEmpty)
    }

    /// A binding is not a condition that can be replaced: the body names what it bound, so
    /// a constant in its place does not compile. A single-clause `if let` therefore yields
    /// nothing at all, which is right.
    @Test("makes nothing of a condition that is a binding")
    func bindingsAreLeftAlone() {
        #expect(
            Self.noOps(
                """
                func f(_ a: Int?) -> Int {
                    if let a { return a }
                    return 0
                }
                """
            ).isEmpty)
        #expect(
            Self.noOps(
                """
                func f(_ a: Int?) -> Int {
                    guard let a else { return 0 }
                    return a
                }
                """
            ).isEmpty)
    }

    /// A `while` too, and with `false` - which is the same answer the keyword-polarity
    /// rule gives for an `if`, because a loop's condition is also the case that runs.
    ///
    /// The hang people reach for as an objection is `while true`, and that is the *other*
    /// column: the same column as `guard false` and `if true`, which this family does not
    /// generate. So `while` needs no exception, only the rule.
    ///
    /// Corrected after this family shipped without it. The mutant it would have missed, in
    /// a real package: `while !input.isReadyForMoreMediaData { await Task.yield() }` - an
    /// encoder waiting for hardware rather than dropping a frame. Making the loop never run
    /// asks whether anything holds that trade in place.
    @Test("makes a loop never run")
    func loopsNeverRun() throws {
        let found = Self.noOps(
            """
            func f(_ limit: Int) -> Int {
                var total = 0
                while total < limit { total += 1 }
                return total
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.original == "total < limit")
        #expect(found.first?.replacement == "false")
    }

    /// Never the direction that would not stop. A mutant that hangs the suite is answered
    /// by the deadline, and the deadline would report it as a detection - a detection about
    /// this tool rather than about the tests.
    @Test("never makes a loop that will not stop")
    func neverAnEndlessLoop() {
        let found = Self.noOps(
            """
            func f(_ limit: Int) -> Int {
                var total = 0
                while total < limit { total += 1 }
                return total
            }
            """)
        #expect(!found.contains { $0.replacement == "true" })
    }

    /// A condition that is already a literal is already this mutant, and the boolean
    /// literal family has it.
    @Test("makes nothing of a condition that is already a constant")
    func alreadyConstant() {
        #expect(Self.noOps("func f() -> Int { if true { return 1 }; return 0 }").isEmpty)
    }

    /// Its own family, because it is its own question and a project turning it off should
    /// not lose the operator swaps in the same conditions.
    @Test("can be turned off on its own")
    func hasItsOwnFamily() {
        // A comparison on the same line, so that "the other families still fire" is a
        // claim the fixture can actually carry.
        let source = """
            // swift-mutants disable next-line condition-decision: not this one
            func f(_ a: Int, _ b: Int) -> Int { if a < b { return 0 }; return a }
            """
        #expect(Self.noOps(source).isEmpty)
        // The comparison, not the whole catalogue: the line is also a statement and holds a
        // literal, and what this asserts is that suppressing one family leaves the others.
        #expect(
            Self.candidates(source).map(\.rule.name).filter { $0 == "lt-to-le" }
                == ["lt-to-le"])
    }
}
