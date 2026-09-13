// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// Turning a byte offset into the place a person would point at.
///
/// Spans are byte offsets everywhere inside this tool, because that is the unit every
/// source of truth agrees on. A person reads `Header.swift:14:11`. This is the one
/// conversion between them, and it is built once per file: doing it per lookup is what
/// makes a walk quadratic in file size.
@Suite("Line index")
struct LineIndexTests {

    static let source = "let a = 1\nlet bb = 22\n\nlet c = 3"

    @Test(
        "points at the line and column a reader would count",
        arguments: [
            (0, 1, 1), (4, 1, 5), (8, 1, 9),
            (9, 1, 10),  // the newline itself ends line one
            (10, 2, 1), (14, 2, 5),
            (22, 3, 1),  // the blank line
            (23, 4, 1), (31, 4, 9),
        ]
    )
    func positions(offset: Int, line: Int, column: Int) throws {
        let index = LineIndex(Self.source)
        let position = try #require(index.position(of: offset))
        #expect(position.line == line, "offset \(offset)")
        #expect(position.column == column, "offset \(offset)")
    }

    /// One past the end is where an insertion at the end of a file would go, so it has a
    /// position; anything further does not.
    @Test("has a position for the end of the file and nothing past it")
    func endOfFile() {
        let index = LineIndex(Self.source)
        #expect(index.position(of: Self.source.utf8.count) != nil)
        #expect(index.position(of: Self.source.utf8.count + 1) == nil)
        #expect(index.position(of: -1) == nil)
    }

    /// Columns are counted in UTF-8 bytes, the same unit the spans are in. Counting
    /// characters would mean two different answers for the same span depending on which
    /// Unicode tables the standard library was built with.
    @Test("counts columns in the same unit the spans are in")
    func columnsAreBytes() throws {
        let index = LineIndex("let s = \"→\"")
        // Nine bytes open the string; the arrow that follows is three more.
        #expect(try #require(index.position(of: 9)).column == 10)
        #expect(try #require(index.position(of: 12)).column == 13)
    }

    @Test("holds an empty file")
    func emptyFile() throws {
        let index = LineIndex("")
        #expect(try #require(index.position(of: 0)).line == 1)
        #expect(index.position(of: 1) == nil)
    }

    @Test("renders as a reader would write it")
    func rendering() throws {
        let index = LineIndex(Self.source)
        #expect(try #require(index.position(of: 14)).description == "2:5")
    }
}

/// Going back the other way: from what a compiler said to where it is.
///
/// A compiler reports `line:col`; a mutant is a byte span. Attribution is the join of the
/// two, so this direction is load-bearing rather than a convenience.
@Suite("LineIndex, in reverse")
struct LineIndexReverseTests {

    /// Swift's own diagnostics count columns in UTF-8 bytes, not characters: an error
    /// after three three-byte arrows is reported at column 30, not 22. Measured against
    /// the pinned toolchain rather than assumed, because a tool that assumed characters
    /// would attribute a diagnostic to the wrong mutant on every line holding a non-ASCII
    /// literal, and would do it silently.
    @Test("counts columns in the unit the compiler uses")
    func columnsAreBytes() throws {
        let index = LineIndex("let x = \"\u{2192}\u{2192}\u{2192}\" + y")
        #expect(index.offset(of: SourcePosition(line: 1, column: 22)) == 21)
    }

    @Test("inverts position lookup at every offset in a file")
    func roundTrips() throws {
        let source = "let a = 1\n\n  let b = 2\nlet c = 3\n"
        let index = LineIndex(source)
        for offset in 0...source.utf8.count {
            let position = try #require(index.position(of: offset))
            #expect(index.offset(of: position) == offset)
        }
    }

    @Test("refuses a position the file does not have")
    func refusesPositionsOutsideTheFile() {
        let index = LineIndex("let a = 1\nlet b = 2\n")
        #expect(index.offset(of: SourcePosition(line: 0, column: 1)) == nil)
        #expect(index.offset(of: SourcePosition(line: 4, column: 1)) == nil)
        #expect(index.offset(of: SourcePosition(line: 1, column: 0)) == nil)
    }

    /// A column past the end of its line would land inside the next one, which is how an
    /// off-by-one in a diagnostic becomes a mutant rejected in the wrong place.
    @Test("refuses a column past the end of its line")
    func refusesColumnsPastTheLine() {
        let index = LineIndex("let a = 1\nlet b = 2\n")
        #expect(index.offset(of: SourcePosition(line: 1, column: 10)) == 9)
        #expect(index.offset(of: SourcePosition(line: 1, column: 11)) == nil)
    }
}
