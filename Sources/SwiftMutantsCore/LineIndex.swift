// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Where in a file a byte offset is, as a person would say it.
public struct SourcePosition: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// The line, counting from one.
    public let line: Int

    /// The column, counting from one, **in UTF-8 bytes**.
    ///
    /// The same unit the spans are in. Counting characters would give two different answers
    /// for one span depending on which Unicode tables the standard library was built with,
    /// and an editor that jumped to the wrong column would be worse than one that jumped to
    /// the right byte.
    public let column: Int

    /// Creates a position.
    ///
    /// Unvalidated on purpose: a position arrives from a compiler diagnostic as often as
    /// from this tool's own arithmetic, and what makes a line or column usable is whether
    /// the file has one, which ``LineIndex`` is the thing that knows.
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    /// `line:column`, the way a compiler writes it and an editor reads it.
    public var description: String { "\(line):\(column)" }

    /// Orders by line first, then by column, the way a person reads a file.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line ? lhs.column < rhs.column : lhs.line < rhs.line
    }
}

/// Converts byte offsets in one file into positions.
///
/// Built once per file and kept. Laying out the line table walks the whole file, so building
/// one per lookup makes any walk over a file quadratic in its size - which is the shape of
/// Muter's `startLocation(for:)`, called once per visited node.
public struct LineIndex: Sendable {

    /// The byte offset each line starts at.
    private let lineStarts: [Int]

    /// For each line, the byte offset each character of it begins at, and one more entry
    /// for where the line ends.
    ///
    /// Kept because the two units cannot be converted without the text: `é` is two bytes
    /// and one character, `🙂` is four, and a family of scalars is more still. Everything
    /// inside this tool counts bytes, because that is what a span is and what the compiler
    /// reports; everything outside it counts characters - the Stryker schema, SARIF, and
    /// every editor that opens a file at `line:column`.
    private let characterStarts: [[Int]]

    /// How long the file is, in bytes.
    private let byteCount: Int

    /// Indexes a file.
    public init(_ source: String) {
        var starts = [0]
        var offset = 0
        for byte in source.utf8 {
            offset += 1
            if byte == UInt8(ascii: "\n") { starts.append(offset) }
        }
        lineStarts = starts
        byteCount = offset

        // One pass over the characters, recording where each begins, with a final entry
        // per line for where the line ends. The sentinel is what makes the lookup a plain
        // search: one past the last character is one column past it, with no special case.
        var characters: [[Int]] = Array(repeating: [], count: starts.count)
        var line = 0
        var byte = 0
        for character in source {
            while line + 1 < starts.count, byte >= starts[line + 1] { line += 1 }
            characters[line].append(byte)
            byte += character.utf8.count
        }
        for line in characters.indices {
            let end = line + 1 < starts.count ? starts[line + 1] : offset
            characters[line].append(end)
        }
        characterStarts = characters
    }

    /// Where `offset` is, or nothing when it is not in the file.
    ///
    /// One past the last byte has a position, because that is where an insertion at the end
    /// of a file goes. Anything further does not.
    public func position(of offset: Int) -> SourcePosition? {
        guard offset >= 0, offset <= byteCount else { return nil }

        // The last line whose start is at or before the offset.
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return SourcePosition(line: low + 1, column: offset - lineStarts[low] + 1)
    }

    /// Where `offset` is, counted in characters rather than in bytes.
    ///
    /// The unit everything outside this tool uses. A byte in the middle of a character
    /// belongs to that character rather than to the next one: rounding forward would put a
    /// position after something that has not ended, and a report that points past a mutant
    /// is a report that sends somebody to the wrong expression.
    public func characterPosition(of offset: Int) -> SourcePosition? {
        guard let place = position(of: offset) else { return nil }
        let starts = characterStarts[place.line - 1]

        // The last entry at or before the offset. The row ends with where the line ends,
        // so a byte one past the last character lands on that and counts as one column
        // past it.
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return SourcePosition(line: place.line, column: low + 1)
    }

    /// Where `position` is, or nothing when the file has no such place.
    ///
    /// The direction a compiler diagnostic arrives in. Swift reports `line:col` with the
    /// column counted in UTF-8 bytes - the same unit spans are in - so this is a lookup
    /// and an addition rather than a re-scan of the line.
    ///
    /// A column past the end of its line is refused rather than clamped. Clamping would
    /// turn an off-by-one in a diagnostic into a byte offset inside the *next* line, and
    /// attribution would then reject a mutant that compiles perfectly well while leaving
    /// the one that does not in the catalogue.
    public func offset(of position: SourcePosition) -> Int? {
        guard position.line >= 1, position.line <= lineStarts.count, position.column >= 1
        else { return nil }

        let start = lineStarts[position.line - 1]
        let end =
            position.line < lineStarts.count ? lineStarts[position.line] - 1 : byteCount
        let offset = start + position.column - 1
        guard offset <= end else { return nil }
        return offset
    }
}
