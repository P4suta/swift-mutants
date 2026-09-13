// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Walks a configuration's characters, remembering where it is.
///
/// Separated from the grammar because the two answer different questions. This one knows
/// what character comes next and which line it is on; the grammar knows what a document is
/// allowed to contain. Keeping the position here is what makes every refusal able to say
/// where it stopped without the grammar having to carry a cursor about.
struct TOMLScanner {

    private let characters: [Character]
    private var index = 0

    /// The line the scanner is on, counting from one the way a reader does.
    private(set) var line = 1

    /// The column the scanner is at, counting from one.
    private(set) var column = 1

    init(_ text: String) {
        characters = Array(text)
    }

    /// The next character, without consuming it.
    func peek() -> Character? {
        index < characters.count ? characters[index] : nil
    }

    /// Consumes and returns the next character.
    @discardableResult
    mutating func advance() -> Character? {
        guard index < characters.count else { return nil }
        let character = characters[index]
        index += 1
        if character == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        return character
    }

    /// Consumes `word` if it is next.
    mutating func matches(_ word: String) -> Bool {
        let letters = Array(word)
        guard index + letters.count <= characters.count,
            Array(characters[index..<(index + letters.count)]) == letters
        else { return false }
        for _ in letters { advance() }
        return true
    }

    /// Consumes `character`, or refuses.
    mutating func expect(_ character: Character) throws(TOMLParseError) {
        guard peek() == character else { throw failure("expected '\(character)'") }
        advance()
    }

    /// Blanks within a line: spaces and tabs, never a newline.
    mutating func skipBlanks() {
        while let next = peek(), next == " " || next == "\t" {
            advance()
        }
    }

    /// Everything between two things that mean something: blanks, newlines, comments.
    mutating func skipInsignificant() {
        while let next = peek() {
            if next == " " || next == "\t" || next == "\n" || next == "\r" {
                advance()
            } else if next == "#" {
                while let inComment = peek(), inComment != "\n" { advance() }
            } else {
                return
            }
        }
    }

    /// Nothing but a comment may follow a value on its line.
    mutating func endOfLine() throws(TOMLParseError) {
        skipBlanks()
        if peek() == "#" {
            while let next = peek(), next != "\n" { advance() }
        }
        guard let next = peek() else { return }
        guard next == "\n" || next == "\r" else {
            throw failure("expected the end of the line")
        }
        advance()
    }

    /// A refusal at the position the scanner has reached.
    func failure(_ reason: String) -> TOMLParseError {
        TOMLParseError(line: line, column: column, reason: reason)
    }

    /// A refusal at a position the grammar remembered earlier.
    func failure(_ reason: String, at line: Int) -> TOMLParseError {
        TOMLParseError(line: line, column: 1, reason: reason)
    }
}
