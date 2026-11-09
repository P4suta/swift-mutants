// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

@Suite("Arithmetic discovery")
struct ArithmeticTests {
    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("Invalid fixture path")
        }
        return path
    }

    @Test(
        "pairs arithmetic operators",
        arguments: [
            ("+", "add-to-sub", "-"), ("-", "sub-to-add", "+"),
            ("*", "mul-to-div", "/"), ("/", "div-to-mul", "*"), ("%", "rem-to-mul", "*"),
        ])
    func pairs(spelling: String, rule: String, replacement: String) {
        let found = Discover.candidates(
            in: "func f(_ a: Int, _ b: Int) -> Int { a \(spelling) b }", at: Self.path()
        ).candidates
        #expect(found.map(\.rule.name) == [rule])
        #expect(found.map(\.original) == [spelling])
        #expect(found.map(\.replacement) == [replacement])
    }

    @Test(
        "keeps the fixed catalogue without optional families",
        arguments: [
            "a & b", "a | b", "a ^ b", "a << b", "a >> b", "a ?? b", "a..<b", "-a", "1",
        ])
    func excludedFamilies(expression: String) {
        let found = Discover.candidates(in: "func f() { \(expression) }", at: Self.path())
        #expect(found.candidates.isEmpty)
    }

    @Test("keeps the expression grouping from operator precedence")
    func precedence() {
        let source = "func f(_ a: Int, _ b: Int, _ c: Int) -> Int { a + b * c }"
        let found = Discover.candidates(in: source, at: Self.path()).candidates
        #expect(found.map(\.rule.name).sorted() == ["add-to-sub", "mul-to-div"])
        let bytes = Array(source.utf8)
        let guarded = found.map {
            String(decoding: bytes[$0.guardSpan.start..<$0.guardSpan.end], as: UTF8.self)
        }
        #expect(Set(guarded) == ["a + b * c", "b * c"])
    }

    @Test(
        "leaves visibly nonnumeric arithmetic to concatenation",
        arguments: [
            #"a + ["x"]"#, #"["x"] + a"#, #""x" + "y""#, #"["x"] + a + b"#,
        ])
    func nonnumeric(expression: String) {
        let found = Discover.candidates(in: "func f() { \(expression) }", at: Self.path())
        #expect(!found.candidates.contains { $0.rule.name == "add-to-sub" })
        #expect(found.skips.contains { $0.reason == .nonNumericOperand })
    }

    @Test("uses suppressions and reports unknown families")
    func suppressions() {
        let found = Discover.candidates(
            in: """
                // swift-mutants disable next-line integer-arithmetic
                func f(_ a: Int, _ b: Int) -> Int { a + b }
                // swift-mutants disable next-line comparisons
                func g(_ a: Int, _ b: Int) -> Bool { a < b }
                """, at: Self.path())
        #expect(!found.candidates.contains { $0.rule.name == "add-to-sub" })
        #expect(found.skips.contains { $0.reason == .disabledByComment })
        #expect(found.unknownSuppressions.map(\.name) == ["comparisons"])
        for family in RuleSelection.families {
            let known = Discover.candidates(
                in: "// swift-mutants disable \(family)", at: Self.path())
            #expect(known.unknownSuppressions.isEmpty)
        }
    }
}
