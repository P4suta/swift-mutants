// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// Replacing what a declaration does with a constant.
///
/// The question every other rule asks is whether one operator is right. This one asks
/// whether the declaration is *tested at all* - whether anything notices when its body
/// stops doing anything. That is a different and much sharper question, and the literature
/// is unusually clear about it: across every project surveyed, a median of one method in
/// ten is covered by tests that assert nothing whatever about it.
///
/// It produces almost no equivalent mutants, because a body that can be replaced by a
/// constant without any test noticing is a finding whichever constant is chosen.
///
/// Only bodies that are a single expression, which is a large part of Swift and all of its
/// computed properties. A body of several statements needs a guard this build cannot place
/// - it would have to prefix a statement inside the braces - and is recorded as a skip
/// rather than passed over in silence.
@Suite("Replacing a body with a constant")
struct BodyReplacementTests {

    static func discover(_ source: String, extreme: Bool = true) -> FileDiscovery {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        mutation.extreme = extreme
        return Discover.candidates(in: source, at: path, selecting: mutation)
    }

    static func bodies(_ discovery: FileDiscovery) -> [Candidate] {
        discovery.candidates.filter { $0.rule.name == "replace-body" }
    }

    /// A span names the bytes it says it does.
    ///
    /// The property every later phase rests on, and the one this rule got wrong first: a
    /// computed property's body was read out of a block built around it rather than out of
    /// the file, and a node in a freshly made parent is a node in a different tree. Every
    /// position inside it is measured from that tree's start, so the span named bytes
    /// somewhere else entirely - and discovery, being consistent with itself, said nothing.
    ///
    /// Only a compiler could see it, and did: the instrumented file came back shredded
    /// mid-token. This is the cheap version of that gate, in the tier that runs on every
    /// change.
    static func assertSpansAreExact(_ discovery: FileDiscovery, in source: String) {
        let bytes = Array(source.utf8)
        for candidate in Self.bodies(discovery) {
            let slice = String(
                decoding: bytes[candidate.span.start..<candidate.span.end], as: UTF8.self)
            #expect(
                slice == candidate.original,
                "the span names '\(slice)' and the candidate says '\(candidate.original)'")
        }
    }

    /// Where this rule reaches into a declaration that is `public`, which is where the
    /// shredding was found.
    @Test("names the bytes it says it does, in a declaration of any visibility")
    func spansAreExact() {
        for source in [
            "struct S { var total: Int { items.reduce(0, +) } }",
            "public struct S { public var total: Int { items.reduce(0, +) } }",
            "public struct S {\n    var a = 0\n    public var total: Int { a + 1 }\n}",
            "func over() -> Bool { items.count > 3 }",
        ] {
            Self.assertSpansAreExact(Self.discover(source), in: source)
        }
    }

    @Test("replaces a boolean body with a constant")
    func boolean() {
        let found = Self.bodies(Self.discover("func empty() -> Bool { items.isEmpty }"))
        #expect(found.count == 1, "\(found.map(\.original))")
        #expect(found.first?.original == "items.isEmpty")
        #expect(found.first?.replacement == "false")
    }

    @Test("replaces a numeric body with zero")
    func numeric() {
        let found = Self.bodies(Self.discover("func size() -> Int { items.count }"))
        #expect(found.first?.replacement == "0")
    }

    @Test("replaces a string body with nothing")
    func string() {
        let found = Self.bodies(Self.discover("func name() -> String { first + last }"))
        #expect(found.first?.replacement == "\"\"")
    }

    @Test("replaces an optional body with nil")
    func optional() {
        let found = Self.bodies(Self.discover("func found() -> Entry? { entries.first }"))
        #expect(found.first?.replacement == "nil")
    }

    @Test("replaces a collection body with an empty one")
    func collections() {
        #expect(
            Self.bodies(Self.discover("func all() -> [Int] { items.sorted() }"))
                .first?.replacement == "[]")
        #expect(
            Self.bodies(Self.discover("func byName() -> [String: Int] { table }"))
                .first?.replacement == "[:]")
    }

    /// A computed property is a body like any other, and is where this rule finds the most:
    /// they are the declarations most likely to be exercised by every test and asserted on
    /// by none.
    @Test("replaces a computed property's body")
    func computedProperty() {
        let found = Self.bodies(
            Self.discover("struct S { var total: Int { items.reduce(0, +) } }"))
        #expect(found.count == 1, "\(found.map(\.original))")
        #expect(found.first?.replacement == "0")
    }

    /// A body that already is the constant would be replaced by itself, which is a mutant
    /// that cannot fail and a line in every report that means nothing.
    @Test("offers nothing when the body already is the constant")
    func alreadyTheConstant() {
        #expect(Self.bodies(Self.discover("func no() -> Bool { false }")).isEmpty)
    }

    /// A return type this cannot spell a value for is a skip with a name, not a silence.
    /// `some P`, `any P` and a generic parameter have no value anybody can write down.
    @Test("passes over a return type it cannot spell a value for")
    func unspellable() {
        let discovery = Self.discover("func make() -> some Equatable { 1 }")
        #expect(Self.bodies(discovery).isEmpty)
        #expect(discovery.skips.contains { $0.reason == .unspellableReturnType })
    }

    /// A body of several statements needs a guard placed inside the braces, which this
    /// build does not do. Said, because a reader comparing two files and finding the
    /// shorter one untouched deserves to know it was a limit rather than a judgement.
    @Test("passes over a body of several statements, and says so")
    func severalStatements() {
        let discovery = Self.discover(
            """
            func total() -> Int {
                let sum = items.reduce(0, +)
                return sum * 2
            }
            """)
        #expect(Self.bodies(discovery).isEmpty)
        #expect(discovery.skips.contains { $0.reason == .multiStatementBody })
    }

    /// A function that returns nothing has nothing to replace its body with: an empty body
    /// is not a constant, it is the absence of one, and this build places no statements.
    @Test("passes over a function that returns nothing")
    func returnsNothing() {
        #expect(Self.bodies(Self.discover("func go() { start() }")).isEmpty)
    }

    /// And a caller with no settings at all is not a caller who asked. A default is not a
    /// request: silence says nothing about whether somebody wants their catalogue
    /// multiplied by the number of declarations in their package.
    @Test("offers nothing to a caller that brought no settings")
    func offNoSettings() {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        let discovery = Discover.candidates(
            in: "func empty() -> Bool { items.isEmpty }", at: path)
        #expect(Self.bodies(discovery).isEmpty)
    }

    /// Off unless asked for. It is the one rule that is about declarations rather than
    /// operators, and it multiplies the catalogue by the number of them.
    @Test("offers nothing unless the run asked for it")
    func offWithoutAsking() {
        let discovery = Self.discover(
            "func empty() -> Bool { items.isEmpty }", extreme: false)
        #expect(Self.bodies(discovery).isEmpty)
    }

    /// And the ordinary rules go on working inside a body this one replaced, because they
    /// ask a different question about the same code.
    @Test("leaves the operators inside the body alone")
    func operatorsSurvive() {
        let discovery = Self.discover("func over() -> Bool { items.count > 3 }")
        #expect(Self.bodies(discovery).count == 1)
        #expect(discovery.candidates.contains { $0.rule.name == "gt-to-ge" })
    }
}
