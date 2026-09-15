// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsConfig

/// Reading `.swift-mutants.toml`.
///
/// Written here rather than taken from a library, for two reasons that are different from
/// each other.
///
/// The first is the same one the glob engine has: configuration decides which files are
/// mutated, which decides which mutants exist, which decides every identity in the
/// catalogue. Whether a project's mutation score moves should not depend on which parser
/// happened to be installed.
///
/// The second is that the diagnostics are the point. A configuration this tool cannot
/// understand has to say *where* it stopped and *what* it expected, because the alternative
/// - "could not decode" - sends somebody bisecting their own file. No general-purpose
/// decoder reports an unknown key with the line it was written on, and that is the single
/// most common mistake a configuration file contains.
///
/// The grammar is a deliberate subset. Anything outside it is refused by name rather than
/// half-supported, because a value that parses into something the reader did not mean is
/// worse than one that does not parse.
@Suite("TOML")
struct TOMLTests {

    static func parse(_ text: String) throws -> TOMLTable {
        try TOMLParser.parse(text)
    }

    @Test("reads a key and a string")
    func readsAString() throws {
        let document = try Self.parse(#"profile = "balanced""#)
        #expect(document["profile"]?.string == "balanced")
    }

    @Test("reads integers and booleans")
    func readsScalars() throws {
        let document = try Self.parse(
            """
            version = 1
            strict = false
            jobs = 8
            """
        )
        #expect(document["version"]?.integer == 1)
        #expect(document["strict"]?.boolean == false)
        #expect(document["jobs"]?.integer == 8)
    }

    @Test("reads an array of strings")
    func readsAnArray() throws {
        let document = try Self.parse(#"include = ["Sources/**", "Plugins/**"]"#)
        #expect(document["include"]?.array?.compactMap(\.string) == ["Sources/**", "Plugins/**"])
    }

    @Test("reads an array written across several lines, with a trailing comma")
    func readsAMultiLineArray() throws {
        let document = try Self.parse(
            """
            exclude = [
              "Tests/**",
              "Fixtures/**",
            ]
            """
        )
        #expect(document["exclude"]?.array?.count == 2)
    }

    @Test("reads a table")
    func readsATable() throws {
        let document = try Self.parse(
            """
            [mutation]
            profile = "strong"

            [test]
            timeout = "60s"
            """
        )
        #expect(document["mutation"]?.table?["profile"]?.string == "strong")
        #expect(document["test"]?.table?["timeout"]?.string == "60s")
    }

    @Test("reads a dotted table header")
    func readsADottedTable() throws {
        let document = try Self.parse(
            """
            [report.thresholds]
            high = 80
            """
        )
        #expect(document["report"]?.table?["thresholds"]?.table?["high"]?.integer == 80)
    }

    /// `[[mutation.expect]]` is how a project writes down a survivor it has decided is
    /// evidence rather than a gap, so the array-of-tables form is not optional.
    @Test("reads an array of tables")
    func readsAnArrayOfTables() throws {
        let document = try Self.parse(
            """
            [[mutation.expect]]
            id = "aaaa"
            reason = "equivalent"

            [[mutation.expect]]
            id = "bbbb"
            reason = "unreachable"
            """
        )
        let rows = try #require(document["mutation"]?.table?["expect"]?.array)
        #expect(rows.count == 2)
        #expect(rows[1].table?["id"]?.string == "bbbb")
    }

    @Test("ignores comments and blank lines")
    func ignoresComments() throws {
        let document = try Self.parse(
            """
            # which files to mutate
            include = ["Sources/**"]  # everything shipped

            # and which not to
            exclude = []
            """
        )
        #expect(document["include"]?.array?.count == 1)
        #expect(document["exclude"]?.array?.isEmpty == true)
    }

    @Test("reads escapes inside a basic string")
    func readsEscapes() throws {
        let document = try Self.parse(#"reason = "a \"quoted\" word\nand a newline""#)
        #expect(document["reason"]?.string == "a \"quoted\" word\nand a newline")
    }

    /// A literal string is how a Windows path or a regular expression is written without
    /// every backslash being doubled.
    @Test("reads a literal string without interpreting escapes")
    func readsALiteralString() throws {
        let document = try Self.parse(##"pattern = 'a\nb'"##)
        #expect(document["pattern"]?.string == #"a\nb"#)
    }

    @Test(
        "says where it stopped and what it expected",
        arguments: [
            ("profile = ", 1, "value"),
            ("profile balanced", 1, "="),
            ("[mutation\nprofile = \"x\"", 1, "]"),
            ("include = [\"a\", ]\nexclude = [", 2, "]"),
            ("version = 1\nversion = 2", 2, "version"),
            ("[test]\n[test]", 2, "test"),
        ]
    )
    func refusesWithAPosition(text: String, line: Int, mentions: String) {
        do {
            _ = try Self.parse(text)
            Issue.record("'\(text)' was accepted")
        } catch let failure as TOMLParseError {
            #expect(failure.line == line, "\(failure)")
            #expect(failure.description.contains(mentions), "\(failure)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// Refused by name rather than half-supported. A value that parses into something the
    /// reader did not mean is worse than one that does not parse.
    @Test(
        "refuses what it does not support, by name",
        arguments: [
            ("stamp = 1979-05-27T07:32:00Z", "date"),
            ("ratio = 3.14", "floating-point"),
            ("point = { x = 1, y = 2 }", "inline table"),
            ("hex = 0xdeadbeef", "decimal"),
        ]
    )
    func refusesUnsupportedSyntaxByName(text: String, mentions: String) {
        do {
            _ = try Self.parse(text)
            Issue.record("'\(text)' was accepted")
        } catch let failure as TOMLParseError {
            #expect(failure.description.contains(mentions), "\(failure)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("holds an empty document")
    func emptyDocument() throws {
        #expect(try Self.parse("").isEmpty)
        #expect(try Self.parse("# nothing but a comment\n").isEmpty)
    }

    /// Line numbers are what the whole error story rests on, so they survive a document
    /// whose lines are long, blank, or comments.
    @Test("counts lines the way a reader does")
    func countsLines() {
        let text = """
            # one

            include = ["a"]

            [mutation]

            profile = "balanced"
            oops
            """
        do {
            _ = try Self.parse(text)
            Issue.record("the document was accepted")
        } catch let failure as TOMLParseError {
            #expect(failure.line == 8, "\(failure)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// A string whose content has newlines in it.
    ///
    /// A `[[mutation.custom]]` anchor is Swift somebody copied out of their own file, and
    /// Swift spans lines. Written as an escape it works - `find = "a + b\\n    c"` - but
    /// nobody copies code and then goes through it replacing newlines, and an anchor whose
    /// every quote has to be escaped as well is an anchor nobody gets right first time.
    ///
    /// TOML has the answer already and this reader did not implement it. Raised by a project
    /// migrating 320 hand-written mutations, whose previous format was TSV: a search string
    /// containing a newline silently became two rows there, the second of which read as a
    /// file path. A refusal is better than that and an expressible newline is better still.
    @Test("reads a string written across lines")
    func multilineBasic() throws {
        let table = try TOMLParser.parse(
            """
            find = \"\"\"
            a + b
                c\"\"\"
            """)
        #expect(table["find"]?.string == "a + b\n    c")
    }

    /// The newline straight after the opening delimiter is not content. It is there so the
    /// text can start on its own line, which is the whole reason for writing one this way.
    @Test("does not count the line break that opens it")
    func opensWithoutANewline() throws {
        let table = try TOMLParser.parse("find = \"\"\"\nabc\"\"\"")
        #expect(table["find"]?.string == "abc")
    }

    /// Quotes inside need no escaping, which is most of the point for a Swift anchor: a
    /// string literal in somebody's code is quotes all the way down.
    @Test("takes quotes inside it without escaping")
    func quotesInside() throws {
        let table = try TOMLParser.parse(
            """
            find = \"\"\"
            greet("world")\"\"\"
            """)
        #expect(table["find"]?.string == #"greet("world")"#)
    }

    /// And the literal form, which takes backslashes as themselves - a regular expression,
    /// a Windows path, a Swift escape somebody is anchoring on.
    @Test("reads a literal string written across lines")
    func multilineLiteral() throws {
        let table = try TOMLParser.parse(
            """
            find = '''
            a\\nb
            c'''
            """)
        #expect(table["find"]?.string == "a\\nb\nc")
    }

    /// Unclosed is refused with the line it started on, like everything else this reader
    /// refuses: a file that ends inside a string is a file somebody mistyped, and the place
    /// to look is where it opened rather than where the file ran out.
    @Test("refuses one that is never closed")
    func unclosed() {
        #expect(throws: TOMLParseError.self) {
            try TOMLParser.parse("find = \"\"\"\nabc\n")
        }
    }
}
