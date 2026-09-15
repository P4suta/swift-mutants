// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// The mutants of one file, arranged the way the syntax nests them.
///
/// A file's mutants are not independent edits. Several share a site — one expression, three
/// rules — and others nest, because the expression one mutant rewrites sits inside the
/// statement another one replaces. Splicing them as a flat list would either corrupt the
/// file or force each mutant to carry its own copy of it.
///
/// Arranging them as a forest is what keeps the instrumented file growing in proportion to
/// **the total size of the rewritten expressions** rather than to the number of mutants
/// times the size of the file. Each site is written once with its mutants as alternatives
/// inside it, and the sites nest the way the syntax does, so the splicer can work
/// innermost-first through an offset map.
///
/// Building is `O(n log n)` for the sort and `O(n)` for one stack pass over the result; no
/// span is compared against more than the stack above it.
public struct IntervalForest<Value>: Sendable where Value: Sendable {

    /// One site, and everything that happens at it.
    public struct Node: Sendable {

        /// The bytes this site covers.
        public let span: SourceSpan

        /// The mutants at exactly this span, in the order they were given.
        ///
        /// Plural because a site with three rules applied to it is one site. Keeping them
        /// together is what lets instrumentation emit one guard chain rather than three
        /// copies of the surrounding bytes.
        public let values: [Value]

        /// Sites strictly inside this one.
        public let children: [Self]
    }

    /// The outermost sites, ordered by position.
    public let roots: [Node]

    /// Every site, innermost first, then left to right.
    ///
    /// This is the order the splicer needs: an inner edit has to be written before the
    /// bytes around it move, or its offsets would be measured against a file that no longer
    /// exists.
    public var innermostFirst: [Node] {
        var visited: [Node] = []
        func visit(_ node: Node) {
            for child in node.children { visit(child) }
            visited.append(node)
        }
        for root in roots { visit(root) }
        return visited
    }

    /// A site under construction, with its children still accumulating.
    private struct Building {
        let span: SourceSpan
        var values: [Value]
        var children: [Node]
    }

    /// Arranges spans into a forest, or refuses a set that cannot be spliced.
    ///
    /// Refused when two spans overlap without one containing the other. Whichever went in
    /// first would destroy the bytes the other was measured against, so there is no order
    /// in which both can be written and a forest that accepted them would produce a file
    /// nobody chose.
    ///
    /// The arrangement does not depend on the order the entries arrive in: they are sorted
    /// by start ascending and then by end *descending*, which puts an enclosing span
    /// immediately before everything it encloses.
    public init?(_ entries: [(span: SourceSpan, value: Value)]) {
        var conflict: Conflict?
        let built = Self.arranging(entries, refusing: &conflict)
        guard conflict == nil else { return nil }
        roots = built
    }

    /// Two sites no splice order can satisfy, if this set holds any.
    ///
    /// The same rule the forest is built by, asked as a question rather than answered with
    /// a refusal. A caller told only that a file cannot be spliced has to read the file and
    /// guess which two places are at fault - and somebody did, by grepping a catalogue for
    /// the filename, which worked only because they already suspected their own rows.
    public static func conflict(in entries: [(span: SourceSpan, value: Value)]) -> Conflict? {
        var conflict: Conflict?
        _ = Self.arranging(entries, refusing: &conflict)
        return conflict
    }

    /// Two spans that overlap without either containing the other.
    ///
    /// Whichever were written first would destroy the bytes the other was measured
    /// against, so there is no order in which both can be written.
    public struct Conflict: Sendable, Hashable {

        /// The one that starts first, or is the wider of two that start together.
        public let earlier: SourceSpan

        /// The one that runs past the end of it without being inside it.
        public let later: SourceSpan
    }

    /// Arranges the spans, and records the first pair that cannot be.
    ///
    /// One loop for both questions, so that "can this be spliced" and "what stopped it"
    /// can never come to different answers.
    private static func arranging(
        _ entries: [(span: SourceSpan, value: Value)], refusing conflict: inout Conflict?
    ) -> [Node] {
        let sorted = entries.enumerated().sorted { left, right in
            if left.element.span.start != right.element.span.start {
                return left.element.span.start < right.element.span.start
            }
            if left.element.span.end != right.element.span.end {
                // Wider first, so a parent is seen before its children.
                return left.element.span.end > right.element.span.end
            }
            // Same span: keep the order the caller gave, so a catalogue is reproducible.
            return left.offset < right.offset
        }

        var stack: [Building] = []
        var finishedRoots: [Node] = []

        func close(_ building: Building) -> Node {
            Node(span: building.span, values: building.values, children: building.children)
        }

        for entry in sorted {
            let span = entry.element.span

            // Anything on the stack that this span has passed is finished. Leaving a
            // site behind is only legal when the new span is entirely past it: a span that
            // overlaps the one it is leaving belongs to neither, and no splice order
            // satisfies both, because whichever is written first destroys the bytes the
            // other was measured against.
            while let top = stack.last, !top.span.contains(span) {
                guard !top.span.overlaps(span) else {
                    conflict = conflict ?? Conflict(earlier: top.span, later: span)
                    return finishedRoots
                }
                let node = close(stack.removeLast())
                if stack.isEmpty {
                    finishedRoots.append(node)
                } else {
                    stack[stack.count - 1].children.append(node)
                }
            }

            // Sharing a span with the site on top means sharing the site.
            if var top = stack.last, top.span == span {
                top.values.append(entry.element.value)
                stack[stack.count - 1] = top
                continue
            }

            stack.append(Building(span: span, values: [entry.element.value], children: []))
        }

        while let top = stack.popLast() {
            let node = close(top)
            if stack.isEmpty {
                finishedRoots.append(node)
            } else {
                stack[stack.count - 1].children.append(node)
            }
        }

        return finishedRoots
    }
}
