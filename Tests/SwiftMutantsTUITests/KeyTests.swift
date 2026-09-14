// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsTUI

/// What a keypress arrives as.
///
/// An arrow key is three bytes, and they do not always arrive together: a terminal is a
/// stream, and a reader that took one byte at a time would see an escape, then a bracket,
/// then a letter - and a reader that treated the bare escape as "quit" would quit every
/// time somebody pressed an arrow. That is the bug this exists to not have.
///
/// So the reader keeps what it could not yet make sense of, and says so.
@Suite("What a keypress arrives as")
struct KeyTests {

    static func read(_ bytes: [UInt8]) -> (keys: [Key], pending: [UInt8]) {
        Key.read(from: bytes)
    }

    @Test(
        "reads the letters somebody types",
        arguments: [
            (UInt8(ascii: "j"), Key.down), (UInt8(ascii: "k"), .up),
            (UInt8(ascii: "q"), .quit), (UInt8(ascii: "\r"), .enter),
            (UInt8(ascii: "\n"), .enter),
        ])
    func readsLetters(_ byte: UInt8, _ key: Key) {
        #expect(Self.read([byte]).keys == [key])
    }

    @Test("reads an arrow that arrived in one piece")
    func readsAnArrow() {
        #expect(Self.read([0x1b, 0x5b, 0x41]).keys == [.up])
        #expect(Self.read([0x1b, 0x5b, 0x42]).keys == [.down])
    }

    /// The bug this exists to not have: a bare escape is the beginning of an arrow that has
    /// not finished arriving, not a keypress of its own.
    @Test(
        "keeps an arrow that has not finished arriving",
        arguments: [[UInt8(0x1b)], [UInt8(0x1b), UInt8(0x5b)]])
    func keepsAPartialArrow(_ bytes: [UInt8]) {
        let read = Self.read(bytes)
        #expect(read.keys.isEmpty)
        #expect(read.pending == bytes)
    }

    /// And it reads as an arrow once the rest turns up.
    @Test("reads an arrow that arrived in pieces")
    func readsASplitArrow() {
        let first = Self.read([0x1b])
        let second = Self.read(first.pending + [0x5b, 0x41])
        #expect(second.keys == [.up])
        #expect(second.pending.isEmpty)
    }

    @Test("reads several keypresses out of one read")
    func readsSeveral() {
        #expect(
            Self.read([UInt8(ascii: "j"), UInt8(ascii: "j"), 0x1b, 0x5b, 0x41]).keys
                == [.down, .down, .up])
    }

    /// A key it has no meaning for is dropped rather than kept: keeping it would make the
    /// next arrow unreadable, because it would arrive behind a byte that is not an escape.
    @Test("drops a key it has no meaning for")
    func dropsTheUnknown() {
        let read = Self.read([UInt8(ascii: "z"), UInt8(ascii: "j")])
        #expect(read.keys == [.down])
        #expect(read.pending.isEmpty)
    }

    /// An escape sequence it does not know is dropped whole, for the same reason: leaving
    /// its tail behind would make the next one unreadable.
    @Test("drops an escape sequence it has no meaning for")
    func dropsUnknownSequences() {
        let read = Self.read([0x1b, 0x5b, 0x43, UInt8(ascii: "j")])
        #expect(read.keys == [.down])
        #expect(read.pending.isEmpty)
    }

    /// Whole means all three bytes, and the middle one has to be the bracket.
    ///
    /// `ESC j A` is not an arrow. A reader that skipped the bracket would call it one; a
    /// reader that stepped one byte at a time would then read the `j` as a keypress of its
    /// own - so the terminal's own escape sequences would type into the browser. Both were
    /// live until this test, which is what perturbing the reader is for.
    @Test("takes the whole of a sequence it does not know, bracket and all")
    func takesTheWholeSequence() {
        let read = Self.read([0x1b, UInt8(ascii: "j"), 0x41, UInt8(ascii: "k")])
        #expect(read.keys == [.up])
        #expect(read.pending.isEmpty)
    }
}
