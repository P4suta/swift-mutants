// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Where in a file a byte offset is, as a person would say it.
public struct SourcePosition: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// The line, counting from one.
    public let line: Int

    /// The UTF-8 byte column, starting at one.
    public let column: Int

    /// Stores a line and byte column without validating a source file.
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

/// Maps UTF-8 byte offsets to source lines, byte columns, and Character columns.
public struct LineIndex: Sendable {

    /// The byte offset each line starts at.
    private let lineStarts: [Int]

    private let characterStarts: [[Int]]

    /// How long the file is, in bytes.
    private let byteCount: Int

    /// Indexes Swift's LF, CR, and CRLF line breaks.
    public init(_ source: String) {
        var starts = [0]
        var offset = 0
        for character in source {
            offset += character.utf8.count
            if SourceLineBreak(rawValue: character) != nil { starts.append(offset) }
        }
        lineStarts = starts
        byteCount = offset

        // Each line ends with a sentinel for its end-of-line position.
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

    /// Returns a one-based line and UTF-8 byte column for an offset.
    /// Accepts the end-of-file offset and rejects offsets outside the source.
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

    /// Returns a one-based line and Character column for an offset.
    /// A byte inside a Character maps to that Character's column.
    public func characterPosition(of offset: Int) -> SourcePosition? {
        guard let place = position(of: offset) else { return nil }
        let starts = characterStarts[place.line - 1]

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

    /// Returns the byte offset for a one-based source line and byte column.
    /// Accepts end-of-file and rejects positions outside their source line.
    public func offset(of position: SourcePosition) -> Int? {
        guard position.line >= 1, position.line <= lineStarts.count, position.column >= 1
        else { return nil }

        let start = lineStarts[position.line - 1]
        let end =
            position.line < lineStarts.count ? lineStarts[position.line] - 1 : byteCount
        let distance = position.column - 1
        guard distance <= end - start else { return nil }
        return start + distance
    }
}
