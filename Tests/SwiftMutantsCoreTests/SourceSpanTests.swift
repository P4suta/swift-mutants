// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsCore

/// `SourceSpan` is the anchor every mutant identity is built on.
///
/// It is a half-open range of **UTF-8 byte offsets**, deliberately not a syntax-tree
/// node identity. Muter keyed its mutation sites on `SwiftSyntax.SyntaxIdentifier` and
/// then re-parsed the file before applying them; the re-parsed nodes carried fresh
/// identities, no key matched, and zero mutants were ever inserted
/// (muter-mutation-testing/muter#307). Byte offsets survive a re-parse because they are
/// facts about the bytes rather than about a particular tree.
@Suite("SourceSpan")
struct SourceSpanTests {

    @Test("carries the half-open byte range it was built from")
    func carriesItsRange() throws {
        let span = try #require(SourceSpan(start: 10, end: 25))
        #expect(span.start == 10)
        #expect(span.end == 25)
        #expect(span.length == 15)
        #expect(!span.isEmpty)
    }

    @Test("an empty span is one whose start and end coincide")
    func emptySpan() throws {
        let span = try #require(SourceSpan(start: 7, end: 7))
        #expect(span.length == 0)
        #expect(span.isEmpty)
    }

    @Test("refuses a range that ends before it starts")
    func refusesInvertedRange() {
        #expect(SourceSpan(start: 9, end: 8) == nil)
    }

    @Test("refuses a negative offset")
    func refusesNegativeOffset() {
        #expect(SourceSpan(start: -1, end: 4) == nil)
        #expect(SourceSpan(start: -3, end: -2) == nil)
    }

    @Test(
        "contains an offset exactly on the half-open interval",
        arguments: [(9, false), (10, true), (24, true), (25, false)]
    )
    func containsOffset(offset: Int, expected: Bool) throws {
        let span = try #require(SourceSpan(start: 10, end: 25))
        #expect(span.contains(offset: offset) == expected)
    }

    @Test("an empty span contains no offset at all")
    func emptySpanContainsNothing() throws {
        let span = try #require(SourceSpan(start: 7, end: 7))
        #expect(!span.contains(offset: 6))
        #expect(!span.contains(offset: 7))
        #expect(!span.contains(offset: 8))
    }

    @Test("contains another span when it encloses the whole of it")
    func containsSpan() throws {
        let outer = try #require(SourceSpan(start: 10, end: 25))
        #expect(outer.contains(try #require(SourceSpan(start: 10, end: 25))))
        #expect(outer.contains(try #require(SourceSpan(start: 12, end: 20))))
        #expect(!outer.contains(try #require(SourceSpan(start: 9, end: 20))))
        #expect(!outer.contains(try #require(SourceSpan(start: 20, end: 26))))
    }

    @Test("overlaps only where the two intervals share an offset")
    func overlaps() throws {
        let span = try #require(SourceSpan(start: 10, end: 25))
        #expect(span.overlaps(try #require(SourceSpan(start: 24, end: 30))))
        #expect(span.overlaps(try #require(SourceSpan(start: 5, end: 11))))
        #expect(!span.overlaps(try #require(SourceSpan(start: 25, end: 30))))
        #expect(!span.overlaps(try #require(SourceSpan(start: 5, end: 10))))
    }

    @Test("an empty span overlaps nothing, not even itself")
    func emptySpanOverlapsNothing() throws {
        let empty = try #require(SourceSpan(start: 7, end: 7))
        #expect(!empty.overlaps(empty))
        #expect(!empty.overlaps(try #require(SourceSpan(start: 0, end: 20))))
    }

    @Test("orders by start, then by end")
    func ordering() throws {
        let spans = [
            try #require(SourceSpan(start: 10, end: 12)),
            try #require(SourceSpan(start: 0, end: 30)),
            try #require(SourceSpan(start: 10, end: 11)),
            try #require(SourceSpan(start: 0, end: 5)),
        ]
        #expect(
            spans.sorted() == [
                try #require(SourceSpan(start: 0, end: 5)),
                try #require(SourceSpan(start: 0, end: 30)),
                try #require(SourceSpan(start: 10, end: 11)),
                try #require(SourceSpan(start: 10, end: 12)),
            ]
        )
    }

    /// The encoded shape is part of the plan format that survives between `list` and
    /// `run`, so it is pinned here rather than left to synthesis.
    @Test("encodes as exactly two integer keys")
    func encodesAsTwoKeys() throws {
        let span = try #require(SourceSpan(start: 10, end: 25))
        #expect(Self.canonicalJSON(of: span) == #"{"end":25,"start":10}"#)
    }

    @Test("decodes what it encoded")
    func codableRoundTrip() throws {
        let span = try #require(SourceSpan(start: 10, end: 25))
        let decoded = try Self.decode(Self.canonicalJSON(of: span))
        #expect(decoded == span)
    }

    @Test("refuses to decode an inverted range")
    func refusesToDecodeInvertedRange() {
        #expect(throws: (any Error).self) {
            try Self.decode(#"{"start":9,"end":8}"#)
        }
    }
}

extension SourceSpanTests {
    /// Encodes with sorted keys so the assertion is about the shape rather than about
    /// whatever order the encoder happened to emit today.
    private static func canonicalJSON(of span: SourceSpan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(span),
            let text = String(data: data, encoding: .utf8)
        else {
            return "<unencodable>"
        }
        return text
    }

    private static func decode(_ json: String) throws -> SourceSpan {
        try JSONDecoder().decode(SourceSpan.self, from: Data(json.utf8))
    }
}
