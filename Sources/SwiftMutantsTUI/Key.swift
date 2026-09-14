// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A keypress, as far as anything here needs to care.
///
/// Small on purpose. A browser with four keys is a browser somebody can use without being
/// told how; one with fifteen is an application, and this is a way of looking at a report.
public enum Key: Sendable, Hashable {
    case up
    case down
    case enter
    case quit
}

extension Key {

    /// The keys in these bytes, and whatever could not yet be made sense of.
    ///
    /// An arrow key is three bytes and they do not always arrive together: a terminal is a
    /// stream, so a reader can see an escape, then a bracket, then a letter. A reader that
    /// treated the bare escape as a keypress of its own would act on it every time somebody
    /// pressed an arrow - so an unfinished sequence is handed back rather than guessed at,
    /// and read again when the rest turns up.
    ///
    /// Anything it has no meaning for is dropped rather than kept. Keeping it would put a
    /// byte that is not an escape in front of the next sequence, and nothing after that
    /// would be readable.
    public static func read(from bytes: [UInt8]) -> (keys: [Key], pending: [UInt8]) {
        var keys: [Key] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            guard byte == 0x1b else {
                if let key = Self.letter(byte) { keys.append(key) }
                index += 1
                continue
            }
            // An escape sequence: ESC [ <letter>. Anything shorter has not finished
            // arriving, and is handed back whole.
            guard index + 2 < bytes.endIndex else {
                return (keys, Array(bytes[index...]))
            }
            if bytes[index + 1] == 0x5b, let key = Self.arrow(bytes[index + 2]) {
                keys.append(key)
            }
            index += 3
        }
        return (keys, [])
    }

    /// What a plain byte means, if it means anything.
    ///
    /// `j` and `k` beside the arrows, because somebody who reads a lot of terminals will
    /// reach for them first and somebody who does not will reach for the arrows.
    private static func letter(_ byte: UInt8) -> Key? {
        switch byte {
        case UInt8(ascii: "j"): .down
        case UInt8(ascii: "k"): .up
        case UInt8(ascii: "q"): .quit
        case UInt8(ascii: "\r"), UInt8(ascii: "\n"): .enter
        default: nil
        }
    }

    /// What the last byte of an escape sequence means, if it means anything.
    private static func arrow(_ byte: UInt8) -> Key? {
        switch byte {
        case 0x41: .up
        case 0x42: .down
        default: nil
        }
    }
}
