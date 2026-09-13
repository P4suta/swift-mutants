// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// Properties the arrangement holds for every set of spans it accepts.
///
/// The examples cover the shapes somebody thought of. These cover the ones nobody did,
/// from printed seeds so a failure can be reproduced rather than hunted for.
@Suite("Interval forest properties")
struct IntervalForestPropertyTests {

    /// Builds a set of spans guaranteed to nest, by recursively splitting a range.
    /// Anything this produces must be accepted, because nothing in it partially overlaps.
    ///
    /// Two shapes are generated on purpose, because without them the ordering rules are
    /// never exercised and these tests pass while pinning nothing:
    ///
    /// - a child that **starts where its parent starts**, which is the only case where
    ///   "wider span first" decides anything;
    /// - a span emitted **twice**, which is the common real case of one expression with
    ///   several rules applied to it, and the only case where the tie-break between equal
    ///   spans decides anything.
    static func nestingSpans(
        in range: Range<Int>,
        depth: Int,
        using generator: inout DeterministicGenerator,
        into found: inout [SourceSpan]
    ) {
        guard let span = SourceSpan(start: range.lowerBound, end: range.upperBound) else { return }
        found.append(span)
        // One site, several mutants.
        if Int.random(in: 0...2, using: &generator) == 0 {
            found.append(span)
        }
        guard depth > 0, range.count > 4 else { return }

        // Half the time the first child shares its parent's start.
        var cursor = Bool.random(using: &generator) ? range.lowerBound : range.lowerBound + 1
        while cursor < range.upperBound - 1 {
            let headroom = max(1, (range.upperBound - 1 - cursor) / 2)
            let width = Int.random(in: 1...headroom, using: &generator)
            let child = cursor..<(cursor + width)
            if Bool.random(using: &generator) {
                nestingSpans(in: child, depth: depth - 1, using: &generator, into: &found)
            }
            cursor += width + Int.random(in: 0...2, using: &generator)
        }
    }

    static func forest(_ spans: [SourceSpan]) -> IntervalForest<Int>? {
        IntervalForest(spans.enumerated().map { (span: $0.element, value: $0.offset) })
    }

    @Test("accepts every set of spans that nests, and keeps all of them", arguments: 0..<200)
    func keepsEveryNestingSpan(seed: Int) throws {
        var generator = DeterministicGenerator(seed: UInt64(seed))
        var spans: [SourceSpan] = []
        Self.nestingSpans(in: 0..<200, depth: 4, using: &generator, into: &spans)

        let forest = try #require(Self.forest(spans), "seed \(seed): nesting spans were refused")
        let kept = forest.innermostFirst.flatMap(\.values).sorted()
        #expect(kept == Array(0..<spans.count), "seed \(seed): a span was lost or duplicated")
    }

    /// The shape the splicer relies on: a child is strictly inside its parent, so writing
    /// the child first cannot disturb where the parent begins.
    @Test("nests only spans that are contained", arguments: 0..<200)
    func childrenAreContained(seed: Int) throws {
        var generator = DeterministicGenerator(seed: UInt64(seed) &+ 500_000)
        var spans: [SourceSpan] = []
        Self.nestingSpans(in: 0..<200, depth: 4, using: &generator, into: &spans)
        let forest = try #require(Self.forest(spans))

        func check(_ node: IntervalForest<Int>.Node) {
            for child in node.children {
                #expect(node.span.contains(child.span), "seed \(seed)")
                #expect(child.span != node.span, "seed \(seed): equal spans must share a site")
                check(child)
            }
        }
        for root in forest.roots { check(root) }
    }

    /// The splicer works through an offset map, so every child has to be visited before the
    /// parent whose bytes would move it.
    @Test("visits every child before its parent", arguments: 0..<200)
    func postOrder(seed: Int) throws {
        var generator = DeterministicGenerator(seed: UInt64(seed) &+ 900_000)
        var spans: [SourceSpan] = []
        Self.nestingSpans(in: 0..<200, depth: 4, using: &generator, into: &spans)
        let forest = try #require(Self.forest(spans))

        var positions: [SourceSpan: Int] = [:]
        for (index, node) in forest.innermostFirst.enumerated() {
            positions[node.span] = index
        }
        func check(_ node: IntervalForest<Int>.Node) {
            guard let parentPosition = positions[node.span] else {
                Issue.record("seed \(seed): \(node.span) is not in the traversal")
                return
            }
            for child in node.children {
                guard let childPosition = positions[child.span] else {
                    Issue.record("seed \(seed): \(child.span) is not in the traversal")
                    continue
                }
                #expect(childPosition < parentPosition, "seed \(seed)")
                check(child)
            }
        }
        for root in forest.roots { check(root) }
    }

    /// A catalogue must come out the same on every machine, so the arrangement cannot
    /// depend on the order discovery happened to walk the file in.
    @Test("arranges the same way whatever order the spans arrive in", arguments: 0..<200)
    func arrivalOrderDoesNotMatter(seed: Int) throws {
        var generator = DeterministicGenerator(seed: UInt64(seed) &+ 1_300_000)
        var spans: [SourceSpan] = []
        Self.nestingSpans(in: 0..<200, depth: 4, using: &generator, into: &spans)
        let shuffled = spans.shuffled(using: &generator)

        let one = try #require(Self.forest(spans))
        let other = try #require(Self.forest(shuffled))
        #expect(
            one.innermostFirst.map(\.span) == other.innermostFirst.map(\.span),
            "seed \(seed)"
        )
    }
}
