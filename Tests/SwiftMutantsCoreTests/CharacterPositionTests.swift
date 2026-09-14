// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// Where a byte offset is, counted the way the rest of the world counts.
///
/// Everything inside this tool is UTF-8 bytes, because that is what a span is and what the
/// Swift compiler reports. Everything outside it is not: the Stryker report schema, SARIF,
/// and every editor that opens a file at `line:column` count characters, and on a line with
/// a `é` or a `🙂` in it the two disagree.
///
/// Getting this wrong is not a rounding error. A report that points four columns to the
/// left of a mutant sends somebody to the wrong expression, and they will believe it,
/// because a number that precise looks like it was measured.
@Suite("Character positions")
struct CharacterPositionTests {

    @Test("agrees with the byte position on a line of ASCII")
    func asciiAgrees() {
        let index = LineIndex("let a = 1\nlet b = 2\n")
        #expect(index.characterPosition(of: 14) == index.position(of: 14))
        #expect(index.characterPosition(of: 14) == SourcePosition(line: 2, column: 5))
    }

    /// `é` is two bytes and one character, so everything after it is one column further
    /// along in bytes than it is on the screen.
    @Test("counts a two-byte character once")
    func twoByteCharacter() {
        let index = LineIndex("let é = 1\n")
        // `=` is at byte 7 and character 6.
        #expect(index.position(of: 7) == SourcePosition(line: 1, column: 8))
        #expect(index.characterPosition(of: 7) == SourcePosition(line: 1, column: 7))
    }

    /// An emoji outside the basic plane is four bytes. Swift counts it as one `Character`,
    /// and so does an editor.
    @Test("counts a four-byte character once")
    func fourByteCharacter() {
        let index = LineIndex("let 🙂 = 1\n")
        #expect(index.position(of: 8) == SourcePosition(line: 1, column: 9))
        #expect(index.characterPosition(of: 8) == SourcePosition(line: 1, column: 6))
    }

    /// A grapheme made of several scalars is one thing a reader sees and one column.
    ///
    /// Written as escapes rather than as the characters themselves. The joiners between
    /// them are invisible, and this repository refuses invisible characters in its source
    /// for the same reason anybody should: a reader cannot see what is there.
    @Test("counts a family of scalars once")
    func combinedGrapheme() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let index = LineIndex("let \(family) = 1\n")
        #expect(
            index.characterPosition(of: "let \(family)".utf8.count)
                == SourcePosition(line: 1, column: 6))
    }

    @Test("starts every line at column one")
    func lineStarts() {
        let index = LineIndex("héllo\nwörld\n")
        #expect(index.characterPosition(of: 0) == SourcePosition(line: 1, column: 1))
        #expect(
            index.characterPosition(of: "héllo\n".utf8.count) == SourcePosition(line: 2, column: 1))
    }

    /// One past the last byte is where an insertion at the end of a file goes.
    @Test("has a position one past the end and none beyond it")
    func pastTheEnd() {
        let index = LineIndex("ab")
        #expect(index.characterPosition(of: 2) == SourcePosition(line: 1, column: 3))
        #expect(index.characterPosition(of: 3) == nil)
        #expect(index.characterPosition(of: -1) == nil)
    }

    /// A byte in the middle of a character belongs to that character, not to half of it.
    /// Rounding forward would put the position after something that has not ended.
    @Test("puts a byte inside a character at that character")
    func insideACharacter() {
        let index = LineIndex("let é = 1\n")
        // Bytes 4 and 5 are the two halves of `é`, which is character 5.
        #expect(index.characterPosition(of: 4) == SourcePosition(line: 1, column: 5))
        #expect(index.characterPosition(of: 5) == SourcePosition(line: 1, column: 5))
    }

    @Test("holds a file with nothing in it")
    func empty() {
        #expect(LineIndex("").characterPosition(of: 0) == SourcePosition(line: 1, column: 1))
    }
}
