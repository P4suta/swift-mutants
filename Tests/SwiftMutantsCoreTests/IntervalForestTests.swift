// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// How the mutants of one file are arranged before any of them is spliced in.
///
/// A file's mutants are not independent edits. Several of them sit at the same site — one
/// expression, three rules — and others nest, because the expression one mutant rewrites
/// lives inside the statement another one replaces. Splicing them as a flat list would
/// either corrupt the file or force every mutant to carry a whole copy of it.
///
/// Grouping them into a forest is what makes the instrumented file grow in proportion to
/// the *size of the rewritten expressions* rather than to the number of mutants times the
/// size of the file. Each site is written once, with its mutants as alternatives inside it,
/// and the sites nest the way the syntax does.
@Suite("Interval forest")
struct IntervalForestTests {

    static func span(_ start: Int, _ end: Int) -> SourceSpan {
        guard let span = SourceSpan(start: start, end: end) else {
            fatalError("malformed span fixture \(start)..<\(end)")
        }
        return span
    }

    /// A span and the value at it, spelled as a struct because SwiftLint refuses a
    /// three-element tuple and is right to: three positional fields at a call site is
    /// three chances to swap two of them.
    struct Entry {
        let start: Int
        let end: Int
        let value: String

        init(_ start: Int, _ end: Int, _ value: String) {
            self.start = start
            self.end = end
            self.value = value
        }
    }

    static func forest(_ entries: [Entry]) -> IntervalForest<String>? {
        IntervalForest(entries.map { (span: Self.span($0.start, $0.end), value: $0.value) })
    }

    @Test("puts spans that do not touch beside each other")
    func disjointSpansAreSiblings() throws {
        let forest = try #require(Self.forest([Entry(0, 5, "a"), Entry(10, 15, "b")]))
        #expect(forest.roots.map(\.span) == [Self.span(0, 5), Self.span(10, 15)])
        #expect(forest.roots.allSatisfy { $0.children.isEmpty })
    }

    @Test("puts a span inside the smallest span that contains it")
    func nestedSpansBecomeChildren() throws {
        let forest = try #require(
            Self.forest([Entry(0, 100, "outer"), Entry(10, 90, "middle"), Entry(20, 30, "inner")])
        )
        #expect(forest.roots.count == 1)
        let outer = try #require(forest.roots.first)
        #expect(outer.values == ["outer"])
        let middle = try #require(outer.children.first)
        #expect(middle.values == ["middle"])
        #expect(middle.children.map(\.values) == [["inner"]])
    }

    /// Three rules producing three mutants of one expression is the common case, not an
    /// edge case. They are alternatives at one site, so they are one node.
    @Test("groups mutants that share a span into one site")
    func identicalSpansShareASite() throws {
        let forest = try #require(
            Self.forest([Entry(10, 20, "a"), Entry(10, 20, "b"), Entry(10, 20, "c")]))
        #expect(forest.roots.count == 1)
        #expect(forest.roots.first?.values == ["a", "b", "c"])
    }

    /// Two edits that overlap without one containing the other cannot both be spliced:
    /// whichever went in first would destroy the bytes the other was measured against. A
    /// forest that accepted them would produce a file nobody chose.
    @Test("refuses spans that overlap without nesting")
    func refusesPartialOverlap() {
        #expect(Self.forest([Entry(0, 20, "a"), Entry(10, 30, "b")]) == nil)
        #expect(Self.forest([Entry(10, 30, "b"), Entry(0, 20, "a")]) == nil)
    }

    /// An empty span is an insertion point, and an insertion point inside a statement
    /// belongs under it.
    @Test("places an empty span under the site that encloses it")
    func emptySpanNests() throws {
        let forest = try #require(Self.forest([Entry(0, 100, "outer"), Entry(50, 50, "point")]))
        #expect(forest.roots.first?.children.map(\.values) == [["point"]])
    }

    /// Splicing runs innermost-first through an offset map: an inner edit must be written
    /// before the bytes around it move.
    @Test("visits innermost sites first")
    func innermostFirstOrder() throws {
        let forest = try #require(
            Self.forest([
                Entry(0, 100, "outer"), Entry(10, 40, "left"), Entry(20, 30, "leftInner"),
                Entry(50, 90, "right"),
            ])
        )
        #expect(
            forest.innermostFirst.map(\.values) == [["leftInner"], ["left"], ["right"], ["outer"]])
    }

    /// A catalogue has to come out the same way on every machine, so the arrangement must
    /// not depend on the order discovery happened to walk the file in.
    @Test("arranges the same way whatever order the spans arrive in")
    func orderOfArrivalDoesNotMatter() throws {
        let ascending = try #require(
            Self.forest([Entry(0, 100, "outer"), Entry(10, 40, "left"), Entry(50, 90, "right")])
        )
        let shuffled = try #require(
            Self.forest([Entry(50, 90, "right"), Entry(0, 100, "outer"), Entry(10, 40, "left")])
        )
        #expect(ascending.innermostFirst.map(\.span) == shuffled.innermostFirst.map(\.span))
    }

    @Test("holds nothing when given nothing")
    func empty() throws {
        let forest = try #require(Self.forest([]))
        #expect(forest.roots.isEmpty)
        #expect(forest.innermostFirst.isEmpty)
    }

    /// The property the whole arrangement exists for: a site appears once however many
    /// mutants it carries.
    @Test("holds one node per distinct span, not one per mutant")
    func siteCountIsIndependentOfMutantCount() throws {
        let manyAtOneSite = (0..<50).map { Entry(10, 20, "m\($0)") }
        let forest = try #require(Self.forest(manyAtOneSite))
        #expect(forest.innermostFirst.count == 1)
        #expect(forest.innermostFirst.first?.values.count == 50)
    }
}
