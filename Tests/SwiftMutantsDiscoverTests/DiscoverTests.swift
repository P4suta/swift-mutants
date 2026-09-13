// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// Finding what could be mutated, and naming what was passed over.
///
/// Discovery is where a run decides what it is about. Everything downstream - the
/// catalogue, the identities, the cache keys, the score - is a consequence of what happens
/// here, so a candidate it invents and a candidate it silently drops are equally serious.
@Suite("Discover")
struct DiscoverTests {

    static func discover(_ source: String) -> FileDiscovery {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return Discover.candidates(in: source, at: path)
    }

    /// The property every later phase rests on: a span names the bytes it says it does.
    static func assertSpansAreExact(_ discovery: FileDiscovery, in source: String) {
        let bytes = Array(source.utf8)
        for candidate in discovery.candidates {
            let slice = String(
                decoding: bytes[candidate.span.start..<candidate.span.end], as: UTF8.self)
            #expect(
                slice == candidate.original,
                "\(candidate.rule) named '\(candidate.original)' but the file has '\(slice)'")
            #expect(candidate.guardSpan.contains(candidate.span))
        }
    }

    @Test("finds a comparison, and names the bytes it would change")
    func findsAComparison() {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { return a < b }"
        let discovery = Self.discover(source)
        Self.assertSpansAreExact(discovery, in: source)

        let comparison = discovery.candidates.filter { $0.rule.name == "lt-to-le" }
        #expect(comparison.count == 1)
        #expect(comparison.first?.original == "<")
        #expect(comparison.first?.replacement == "<=")
        // The guard wraps the whole comparison, not only the operator.
        let guardSpan = comparison.first?.guardSpan
        #expect(
            String(
                decoding: Array(source.utf8)[(guardSpan?.start ?? 0)..<(guardSpan?.end ?? 0)],
                as: UTF8.self)
                == "a < b"
        )
    }

    @Test(
        "knows the comparisons it can swap",
        arguments: [
            ("a < b", "lt-to-le", "<="), ("a <= b", "le-to-lt", "<"),
            ("a > b", "gt-to-ge", ">="), ("a >= b", "ge-to-gt", ">"),
            ("a == b", "eq-to-neq", "!="), ("a != b", "neq-to-eq", "=="),
        ]
    )
    func comparisons(expression: String, rule: String, replacement: String) {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { return \(expression) }"
        let found = Self.discover(source).candidates.first { $0.rule.name == rule }
        #expect(found?.replacement == replacement, "\(expression) produced no \(rule)")
    }

    @Test("swaps the logical connectives")
    func connectives() {
        let source = "func f(_ a: Bool, _ b: Bool) -> Bool { return a && b || a }"
        let discovery = Self.discover(source)
        Self.assertSpansAreExact(discovery, in: source)
        #expect(discovery.candidates.contains { $0.rule.name == "and-to-or" })
        #expect(discovery.candidates.contains { $0.rule.name == "or-to-and" })
    }

    /// `a && b || c` groups as `(a && b) || c`. A mutation of the `||` therefore wraps the
    /// whole expression and one of the `&&` wraps only its left part - which is only
    /// knowable once precedence has been resolved, and is why the tree is folded first.
    @Test("wraps the expression precedence says it should")
    func guardSpanFollowsPrecedence() {
        let source = "func f(_ a: Bool, _ b: Bool, _ c: Bool) -> Bool { return a && b || c }"
        let bytes = Array(source.utf8)
        let discovery = Self.discover(source)

        func wrapped(_ rule: String) -> String? {
            guard let candidate = discovery.candidates.first(where: { $0.rule.name == rule })
            else { return nil }
            return String(
                decoding: bytes[candidate.guardSpan.start..<candidate.guardSpan.end],
                as: UTF8.self
            )
        }
        #expect(wrapped("and-to-or") == "a && b")
        #expect(wrapped("or-to-and") == "a && b || c")
    }

    @Test("swaps a boolean literal")
    func booleanLiterals() {
        let source = "func f() -> Bool { return true }"
        let discovery = Self.discover(source)
        Self.assertSpansAreExact(discovery, in: source)
        #expect(
            discovery.candidates.first { $0.rule.name == "true-to-false" }?.replacement == "false")
    }

    /// Google's measurement is the argument: suppressing what cannot be asserted on took
    /// the median mutant count for a change from 820 to 7, and the productivity of what was
    /// left from 15% to 89%. Logging is the single highest-yield rule they have.
    @Test(
        "passes over what no test could reasonably assert on",
        arguments: [
            "print(a < b)",
            "debugPrint(a < b)",
            "logger.info(\"\\(a < b)\")",
            "log.debug(\"\\(a < b)\")",
            "assert(a < b)",
            "precondition(a < b)",
            "assertionFailure(\"\\(a < b)\")",
        ]
    )
    func aridCallsAreSkipped(call: String) {
        let source = "func f(_ a: Int, _ b: Int) { \(call) }"
        let discovery = Self.discover(source)
        #expect(
            discovery.candidates.isEmpty,
            "\(call) produced \(discovery.candidates.count) candidates")
        #expect(discovery.skips.contains { $0.reason == .arid })
    }

    /// Nothing is dropped in silence. A skip records how many candidates its reason hid, so
    /// `list --explain` can answer "why is this smaller than I expected".
    @Test("counts what each reason passed over")
    func skipsCountWhatTheyHid() {
        let source = "func f(_ a: Int, _ b: Int) { print(a < b && a > b) }"
        let discovery = Self.discover(source)
        let arid = discovery.skips.filter { $0.reason == .arid }
        #expect(arid.count == 1)
        // Five: a shift at each of the two comparisons, and three at the conjunction -
        // the swap and the two prunes that drop one operand each. The count is of what the
        // region would have yielded, not of what is obvious from reading the line.
        #expect(arid.first?.candidatesHidden == 5)
    }

    @Test("still mutates what sits beside something arid")
    func aridIsLocal() {
        let source = """
            func f(_ a: Int, _ b: Int) -> Bool {
                print(a < b)
                return a > b
            }
            """
        let discovery = Self.discover(source)
        #expect(discovery.candidates.count == 1)
        #expect(discovery.candidates.first?.rule.name == "gt-to-ge")
    }

    /// A macro's arguments become code nobody wrote, and a guard spliced into one expands
    /// into types the surrounding code cannot hold. Muter reported exactly this against
    /// `#Predicate`, where the build failed with the error hidden in a macro buffer.
    @Test("passes over the inside of a macro expansion")
    func macroSitesAreSkipped() {
        let source = """
            func f(_ a: Int, _ b: Int) -> Bool {
                #myMacro(a < b)
            }
            """
        let discovery = Self.discover(source)
        #expect(discovery.candidates.isEmpty)
        #expect(discovery.skips.contains { $0.reason == .macroExpansion })
    }

    @Test("obeys a comment that asks it not to")
    func commentPragmas() {
        let source = """
            func f(_ a: Int, _ b: Int) -> Bool {
                // swift-mutants disable next-line comparison
                let first = a < b
                return first && a > b
            }
            """
        let discovery = Self.discover(source)
        #expect(!discovery.candidates.contains { $0.rule.name == "lt-to-le" })
        #expect(discovery.candidates.contains { $0.rule.name == "gt-to-ge" })
        #expect(discovery.skips.contains { $0.reason == .disabledByComment })
    }

    @Test("obeys a region a comment turned off")
    func commentRegions() {
        let source = """
            func f(_ a: Int, _ b: Int) -> Bool {
                // swift-mutants disable all
                let first = a < b
                let second = a > b
                // swift-mutants restore all
                return first && second || a == b
            }
            """
        let discovery = Self.discover(source)
        #expect(!discovery.candidates.contains { $0.rule.name == "lt-to-le" })
        #expect(!discovery.candidates.contains { $0.rule.name == "gt-to-ge" })
        #expect(discovery.candidates.contains { $0.rule.name == "eq-to-neq" })
    }

    /// A user-defined operator has no meaning this tool knows, so swapping it would be
    /// swapping something for something else at random.
    @Test("leaves an operator it does not know alone")
    func unknownOperatorsAreLeftAlone() {
        let source = """
            infix operator <~>
            func f(_ a: Int, _ b: Int) -> Bool { return a <~> b }
            """
        let discovery = Self.discover(source)
        #expect(discovery.candidates.isEmpty)
    }

    @Test("names the declaration an edit sits inside")
    func namesTheEnclosingDeclaration() {
        let source = """
            struct Header {
                func parse(_ a: Int, _ b: Int) -> Bool { return a < b }
            }
            """
        let discovery = Self.discover(source)
        #expect(discovery.candidates.first?.enclosingDeclaration == "Header.parse")
    }

    /// A catalogue has to come out the same on every machine, and a file is walked once, so
    /// the order is the file's order.
    @Test("returns candidates in the order they appear in the file")
    func deterministicOrder() {
        let source = """
            func f(_ a: Int, _ b: Int) -> Bool {
                let first = a < b
                let second = a > b
                return first || second
            }
            """
        let discovery = Self.discover(source)
        #expect(
            discovery.candidates.map(\.span.start)
                == discovery.candidates.map(\.span.start).sorted())
    }

    @Test("digests the file it read")
    func digestsTheSource() {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { return a < b }"
        #expect(Self.discover(source).sourceDigest == Digest.of(source))
    }

    @Test("finds nothing in a file with nothing to find")
    func emptyFile() {
        let discovery = Self.discover("// just a comment\n")
        #expect(discovery.candidates.isEmpty)
        #expect(discovery.skips.isEmpty)
    }
}
