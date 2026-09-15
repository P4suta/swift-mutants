// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// Dropping one clause of a condition list.
///
/// A comma-separated condition list *is* `&&`, so this is the question `and-keep-lhs`
/// already asks - "is this operand load-bearing" - in the syntax people actually write
/// conditions in. The prune rules did not fire on it, because they look for the operator
/// and the source has commas.
///
/// Measured on a real package by somebody who had written the mutations by hand: clauses
/// dropped from a condition list, together with the single-clause case, were fifty-five of
/// their two hundred and ninety hand-written mutations - nineteen per cent, the largest
/// generatable family they had. Three of the six holes they closed in one session were a
/// guard clause that could never fire: a check enforced where the cuts are made and checked
/// again where they are summed, a zoom limit applied per axis where the scale already
/// clamped it. Each read as the thing keeping something honest, and each was dead.
@Suite("Dropping a clause from a condition list")
struct ConditionListTests {

    static func candidates(_ source: String) -> [Candidate] {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return Discover.candidates(in: source, at: path).candidates
    }

    static func drops(_ source: String) -> [Candidate] {
        Self.candidates(source).filter { $0.rule.name == "drop-condition" }
    }

    /// The shape reported, verbatim.
    @Test("drops each clause of a guard in turn")
    func dropsEachGuardClause() {
        let drops = Self.drops(
            """
            func f(_ text: String) -> Double? {
                guard let scale = Double(text), scale > 0, scale.isFinite else { return nil }
                return scale
            }
            """)
        // The two that can go. The binding cannot: everything after it names `scale`.
        #expect(drops.count == 2)
        #expect(Set(drops.map(\.original)) == ["scale > 0", "scale.isFinite"])
        #expect(drops.allSatisfy { $0.replacement == "true" })
    }

    @Test("drops a clause of an if, and of a while")
    func dropsIfAndWhile() {
        #expect(Self.drops("func f(_ a: Bool, _ b: Bool) { if a, b { print(1) } }").count == 2)
        #expect(
            Self.drops("func f(_ a: Bool, _ b: Bool) { while a, b { break } }").count == 2)
    }

    /// One condition is not a list, and replacing it with nothing is not a condition. The
    /// single-clause case is a different mutation and is not this one.
    @Test("drops nothing from a condition that is not a list")
    func singleCondition() {
        #expect(Self.drops("func f(_ a: Bool) { if a { print(1) } }").isEmpty)
        #expect(
            Self.drops("func f(_ a: Bool) -> Int { guard a else { return 0 }; return 1 }").isEmpty)
    }

    /// A binding is not a clause that can be dropped: everything after it, and the body,
    /// may name what it bound. The compiler would refuse it, and a refusal costs a compile
    /// to learn something that was knowable from the syntax.
    @Test("never drops a binding")
    func neverDropsABinding() {
        let drops = Self.drops(
            """
            func f(_ text: String?) -> Int {
                guard let text, !text.isEmpty else { return 0 }
                return text.count
            }
            """)
        #expect(drops.count == 1)
        #expect(drops.first?.original == "!text.isEmpty")
    }

    /// A list of nothing but bindings has no clause to drop.
    @Test("drops nothing from a list of bindings")
    func onlyBindings() {
        #expect(
            Self.drops(
                """
                func f(_ a: Int?, _ b: Int?) -> Int {
                    guard let a, let b else { return 0 }
                    return a + b
                }
                """
            ).isEmpty)
    }

    /// A `case` clause binds too, and for the same reason it is left alone.
    @Test("never drops a case clause")
    func neverDropsACase() {
        #expect(
            Self.drops(
                """
                func f(_ a: Int?, _ b: Bool) -> Int {
                    guard case .some(let value) = a, b else { return 0 }
                    return value
                }
                """
            ).count == 1)
    }

    /// The same family as the other prunes, because it is the same question asked of the
    /// same thing: a comma-separated list is `&&` with different punctuation. The family is
    /// what a suppression comment names and what a profile selects, so putting it anywhere
    /// else would make `// swift-mutants disable boolean-connective` silence half of one
    /// idea.
    @Test("belongs with the other prunes")
    func belongsWithThePrunes() {
        let source = """
            // swift-mutants disable next-line boolean-connective: not this one
            func f(_ a: Bool, _ b: Bool) { if a, b { print(1) } }
            """
        #expect(Self.drops(source).isEmpty)
        #expect(!Self.drops("func f(_ a: Bool, _ b: Bool) { if a, b { print(1) } }").isEmpty)
    }

    /// The span is one clause, not the list. A list is not an expression - it cannot be
    /// wrapped in a ternary - and a mutant spanning one would need a statement-level guard.
    /// One clause is an expression, and `true` in its place is the same program as dropping
    /// it. Found by compiling the first version, which was not Swift.
    @Test("replaces one clause rather than the list")
    func replacesOneClause() throws {
        let source = "func f(_ a: Bool, _ b: Bool) { if a, b { print(1) } }"
        let drops = Self.drops(source)
        let bytes = Array(source.utf8)
        let spans = drops.map {
            String(decoding: bytes[$0.span.start..<$0.span.end], as: UTF8.self)
        }
        #expect(Set(spans) == ["a", "b"])
        #expect(drops.allSatisfy { $0.replacement == "true" })
    }

    /// Three clauses give three mutants, each asking about one of them, rather than one
    /// mutant that drops several and asks about none of them in particular.
    @Test("asks about one clause at a time")
    func oneAtATime() {
        let drops = Self.drops(
            "func f(_ a: Bool, _ b: Bool, _ c: Bool) { if a, b, c { print(1) } }")
        #expect(drops.count == 3)
        #expect(Set(drops.map(\.original)) == ["a", "b", "c"])
    }
}
