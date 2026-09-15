// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Strings that span lines.
///
/// Its own file because it exists for one kind of value: a `[[mutation.custom]]` anchor
/// is Swift somebody copied out of their own file, and Swift spans lines. Written with
/// escapes it works - and nobody copies code and then goes through it replacing newlines,
/// nor escapes every quote in a string literal they are anchoring on.
///
/// TOML has had both forms all along; this reader simply did not take them.
extension Parser {

    /// A basic string, on one line or across several.
    ///
    /// Three quotes open one that spans lines. A `[[mutation.custom]]` anchor is Swift
    /// somebody copied out of their own file and Swift spans lines, so an anchor that had
    /// to be written with `\\n` escapes - and every quote in it escaped as well - was an
    /// anchor nobody got right first time. TOML has had this form all along.
    mutating func anyBasicString() throws(TOMLParseError) -> String {
        guard scanner.matches("\"\"\"") else { return try basicString() }
        return try acrossLines(closedBy: "\"\"\"", escaping: true)
    }

    /// A literal string, on one line or across several.
    ///
    /// The literal form takes a backslash as itself, which is what a regular expression or
    /// a Swift escape being anchored on needs.
    mutating func anyLiteralString() throws(TOMLParseError) -> String {
        guard scanner.matches("\'\'\'") else { return try literalString() }
        return try acrossLines(closedBy: "\'\'\'", escaping: false)
    }

    /// The body of a string written across lines.
    ///
    /// The newline straight after the opening delimiter is not content: it is there so the
    /// text can start on its own line, which is the whole reason for writing one this way.
    /// TOML says to drop exactly one, and dropping more would quietly eat a blank first line
    /// somebody meant.
    ///
    /// Unclosed is refused with the position it ran out at, like everything else here. A
    /// file that ends inside a string is a file somebody mistyped.
    mutating func acrossLines(
        closedBy delimiter: String, escaping: Bool
    ) throws(TOMLParseError) -> String {
        if scanner.peek() == "\r" { _ = scanner.advance() }
        if scanner.peek() == "\n" { _ = scanner.advance() }
        var text = ""
        while scanner.peek() != nil {
            if scanner.matches(delimiter) { return text }
            guard let next = scanner.advance() else { break }
            guard escaping, next == "\\" else {
                text.append(next)
                continue
            }
            guard let escape = scanner.advance() else {
                throw scanner.failure("expected an escape")
            }
            guard let replacement = Self.escapes[escape] else {
                throw scanner.failure("'\\\(escape)' is not an escape this reader knows")
            }
            text.append(replacement)
        }
        throw scanner.failure("expected '\(delimiter)' to close the string")
    }
}
