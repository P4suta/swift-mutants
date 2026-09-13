// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A half-open range of UTF-8 byte offsets into one source file: `[start, end)`.
///
/// Every mutant this tool produces is anchored to a `SourceSpan` rather than to a
/// syntax-tree node. That is not a stylistic preference. Muter keyed its mutation sites
/// on `SwiftSyntax.SyntaxIdentifier`, then re-parsed each file before splicing them in;
/// the re-parsed nodes carried fresh identities, not one key matched, and **zero**
/// mutants were inserted into builds that went on to report four hundred false
/// regressions (muter-mutation-testing/muter#307). A byte offset is a fact about the
/// bytes, so it survives a re-parse, a different `SwiftSyntax` version, and a trip
/// through a JSON plan file.
///
/// Offsets are UTF-8 bytes because that is the unit `SwiftSyntax.AbsolutePosition`,
/// `swiftc -dump-ast`'s `range` field, and the compiler's own diagnostics all agree on.
/// Counting `Character`s or UTF-16 code units would need a conversion at every join.
public struct SourceSpan: Sendable, Hashable, Comparable, Codable {

    /// The first byte of the span, zero-based and inclusive.
    public let start: Int

    /// One past the last byte of the span, zero-based and exclusive.
    public let end: Int

    /// Creates a span, or `nil` when the offsets could not describe one.
    ///
    /// The two ways to fail are a negative offset and an `end` before its `start`.
    /// Both are rejected here rather than trapped, because spans arrive from a
    /// compiler diagnostic and from a decoded plan file as well as from a syntax tree,
    /// and only the syntax tree can be trusted to have produced a sane pair.
    public init?(start: Int, end: Int) {
        guard start >= 0, end >= start else { return nil }
        self.start = start
        self.end = end
    }

    /// How many UTF-8 bytes the span covers.
    public var length: Int { end - start }

    /// Whether the span covers no bytes at all.
    ///
    /// An empty span still has a position, which is what makes it useful: it names a
    /// point at which something could be inserted.
    public var isEmpty: Bool { start == end }

    /// Whether `offset` falls inside the half-open interval.
    ///
    /// An empty span contains no offset, including its own `start`.
    public func contains(offset: Int) -> Bool {
        offset >= start && offset < end
    }

    /// Whether this span encloses the whole of `other`.
    ///
    /// A span contains itself. Unlike ``overlaps(_:)`` this is a statement about the
    /// interval rather than about the bytes, so an enclosed empty span is contained:
    /// the interval forest needs to place a zero-width edit site under the statement
    /// that surrounds it.
    public func contains(_ other: Self) -> Bool {
        other.start >= start && other.end <= end
    }

    /// Whether the two spans share at least one byte.
    ///
    /// An empty span shares no byte with anything, itself included. That is why the
    /// emptiness guard is here rather than left to the interval arithmetic: the usual
    /// half-open overlap test reports a zero-width span strictly inside another as
    /// overlapping it, which would let an empty edit site claim a conflict over bytes it
    /// does not cover. ``contains(_:)`` deliberately answers the opposite way for the
    /// same pair, because placing a site in the tree and detecting a byte conflict are
    /// different questions.
    public func overlaps(_ other: Self) -> Bool {
        !isEmpty && !other.isEmpty && start < other.end && other.start < end
    }

    /// Orders by `start`, then by `end`; both ascending.
    ///
    /// The interval forest wants enclosing spans before the spans they contain and
    /// sorts with its own comparator. This ordering is the unsurprising one, so that
    /// `sorted()` anywhere else means what a reader expects.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
    }
}

extension SourceSpan {
    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }

    /// Decodes a span, refusing a pair that ``init(start:end:)`` would have refused.
    ///
    /// Synthesised decoding would accept `{"start": 9, "end": 8}` and hand back a value
    /// no constructor could have produced, so the check is repeated here. A plan file is
    /// read back by a later phase, and a span that cannot exist would splice bytes
    /// somewhere nobody chose.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Int.self, forKey: .start)
        let end = try container.decode(Int.self, forKey: .end)
        guard let span = SourceSpan(start: start, end: end) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription:
                        "\(start)..<\(end) is not a source span: offsets must be non-negative and end must not precede start"
                )
            )
        }
        self = span
    }
}

extension SourceSpan {

    /// The same span, moved along by `distance` bytes, or `nil` if that leaves the file.
    ///
    /// Instrumentation builds its output by concatenation, so a span recorded relative to
    /// one piece has to be rebased as that piece is wrapped in the next. Doing the
    /// arithmetic here rather than at each call site is what keeps the wrapping readable.
    ///
    /// Forward shifts - the only kind instrumentation performs - always succeed, since
    /// moving both ends by the same non-negative amount preserves both invariants.
    public func shifted(by distance: Int) -> SourceSpan? {
        SourceSpan(start: start + distance, end: end + distance)
    }
}
