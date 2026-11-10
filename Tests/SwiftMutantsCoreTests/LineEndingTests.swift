// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@Suite("Swift source line endings")
struct LineEndingTests {
    @Test(
        "unrepresentable columns are rejected before offset arithmetic",
        arguments: [Int.min, -1, 0, Int.max - 1, Int.max])
    func columnBounds(column: Int) {
        let index = LineIndex("a\nb")
        #expect(index.offset(of: SourcePosition(line: 2, column: column)) == nil)
    }

    @Test("column arithmetic agrees with an Int128 oracle", arguments: ["\n", "\r", "\r\n"])
    func columnOracle(ending: String) {
        let source = "\u{00E9}\(ending)\u{1F600}"
        let index = LineIndex(source)
        let second = 2 + ending.utf8.count
        let lines = [(1, 0, second - 1), (2, second, source.utf8.count)]
        let columns = [Int.min, Int.max - 1, Int.max] + Array(-1...(source.utf8.count + 2))
        for (line, start, end) in lines {
            for column in columns {
                let wide = Int128(start) + Int128(column) - 1
                let expected = column >= 1 && wide <= Int128(end) ? Int(exactly: wide) : nil
                #expect(index.offset(of: SourcePosition(line: line, column: column)) == expected)
            }
        }
    }

    @Test(
        "indexes every Swift line break and round-trips every byte",
        arguments: ["\n", "\r", "\r\n"])
    func positions(ending: String) throws {
        let source = "\u{00E9}\(ending)\u{1F600}\(ending)"
        let index = LineIndex(source)
        let second = 2 + ending.utf8.count
        #expect(index.position(of: second) == SourcePosition(line: 2, column: 1))
        #expect(index.position(of: source.utf8.count) == SourcePosition(line: 3, column: 1))
        #expect(index.characterPosition(of: second)?.line == 2)
        for offset in 0...source.utf8.count {
            let position = try #require(index.position(of: offset))
            #expect(index.offset(of: position) == offset)
        }
        #expect(index.offset(of: SourcePosition(line: 1, column: second + 1)) == nil)
    }

    @Test("Unicode separators inside literals don't start a Swift source line")
    func literalSeparators() {
        let source = "\"a\u{2028}b\""
        let index = LineIndex(source)
        #expect(index.position(of: source.utf8.count)?.line == 1)
    }
}
