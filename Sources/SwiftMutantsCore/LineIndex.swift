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
}
