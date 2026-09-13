// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsConfig

/// Properties the reader holds for inputs nobody wrote an example of.
///
/// A configuration file is the one input to this tool that a person types by hand, so it is
/// the one most likely to be malformed in a way nobody anticipated. A reader that hangs or
/// traps on such a file is worse than one that refuses it, because the person is then
/// debugging the tool rather than their file.
@Suite("TOML properties")
struct TOMLPropertyTests {

    static let soup = Array("[]{}\"'=#.,\n\t abc012-_+eExXtruefals\\")

    /// Every input either parses or is refused. Neither trapping nor hanging is a third
    /// option, and a parser that made no progress on some character would do the second.
    @Test("terminates on arbitrary input", arguments: 0..<600)
    func terminatesOnArbitraryInput(seed: Int) {
        var generator = DeterministicGenerator(seed: UInt64(seed))
        let text = String(
            (0..<Int.random(in: 0...80, using: &generator)).map { _ in
                Self.soup.randomElement(using: &generator) ?? "a"
            }
        )
        // The assertion is that this returns at all.
        _ = try? TOMLParser.parse(text)
    }

    /// A position that is not in the document is a position nobody can act on, and a
    /// message that points past the end of a file reads as a bug in the tool.
    @Test("reports a position inside the document it refused", arguments: 0..<600)
    func positionsAreInsideTheDocument(seed: Int) {
        var generator = DeterministicGenerator(seed: UInt64(seed) &+ 900_000)
        let text = String(
            (0..<Int.random(in: 1...80, using: &generator)).map { _ in
                Self.soup.randomElement(using: &generator) ?? "a"
            }
        )
        guard case .failure(let error) = Result(catching: { try TOMLParser.parse(text) }),
            let failure = error as? TOMLParseError
        else { return }

        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(failure.line >= 1, "seed \(seed): \(failure)")
        #expect(
            failure.line <= lineCount, "seed \(seed): \(failure) in a \(lineCount)-line document")
        #expect(failure.column >= 1, "seed \(seed): \(failure)")
    }

    /// A document built out of the supported grammar must read back as what it was built
    /// from, whatever order and spacing it happened to get.
    @Test("reads back a document it could have been given", arguments: 0..<300)
    func readsBackAGeneratedDocument(seed: Int) throws {
        var generator = DeterministicGenerator(seed: UInt64(seed) &+ 1_700_000)
        var lines: [String] = []
        var expected: [String: TOMLValue] = [:]

        for index in 0..<Int.random(in: 1...8, using: &generator) {
            let key = "key\(index)"
            let spacing = String(repeating: " ", count: Int.random(in: 0...3, using: &generator))
            switch Int.random(in: 0...3, using: &generator) {
            case 0:
                let number = Int.random(in: -1000...1000, using: &generator)
                lines.append("\(key)\(spacing)=\(spacing)\(number)")
                expected[key] = .integer(number)
            case 1:
                let flag = Bool.random(using: &generator)
                lines.append("\(key)\(spacing)=\(spacing)\(flag)")
                expected[key] = .boolean(flag)
            case 2:
                let text = "v\(Int.random(in: 0...9999, using: &generator))"
                lines.append("\(key)\(spacing)=\(spacing)\"\(text)\"")
                expected[key] = .string(text)
            default:
                let count = Int.random(in: 0...3, using: &generator)
                let items = (0..<count).map { "i\($0)" }
                lines.append("\(key) = [\(items.map { "\"\($0)\"" }.joined(separator: ", "))]")
                expected[key] = .array(items.map { .string($0) })
            }
            if Bool.random(using: &generator) { lines.append("  # a comment") }
            if Bool.random(using: &generator) { lines.append("") }
        }

        let document = try TOMLParser.parse(lines.joined(separator: "\n"))
        for (key, value) in expected {
            #expect(document[key] == value, "seed \(seed): \(key)")
        }
    }
}
