// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Reads `.swift-mutants.toml`.
///
/// A deliberate subset of TOML: comments, bare and dotted keys, basic and literal strings,
/// integers, booleans, arrays, tables, and arrays of tables. That is everything a
/// configuration for this tool needs and nothing else.
///
/// Everything outside the subset is refused **by name** - "a floating-point number", "an
/// inline table" - rather than half-supported. A configuration is read once and then
/// silently decides which files get mutated for the rest of the run, so a value that parses
/// into something the reader did not mean is worse than one that does not parse.
///
/// Written here rather than taken from a library for the same reason the glob engine is:
/// whether a project's mutation score moves should not depend on which parser was
/// installed. And because the diagnostics are half the value - no general-purpose decoder
/// reports a key with the line it was written on, and that is the single most common
/// mistake a configuration contains.
public enum TOMLParser {

    /// Reads a document, or says where it stopped.
    public static func parse(_ text: String) throws(TOMLParseError) -> TOMLTable {
        var parser = Parser(text: text)
        return try parser.document()
    }
}

/// The grammar. Where the scanner knows what character is next, this knows what a document
/// is allowed to contain.
private struct Parser {

    private var scanner: TOMLScanner

    /// The root, and the table that keys are currently being added to.
    private var root = TOMLTable()
    private var currentPath: [String] = []

    /// Every table header seen, so a second one can be refused.
    private var declaredTables: Set<String> = []

    init(text: String) {
        scanner = TOMLScanner(text)
    }

    mutating func document() throws(TOMLParseError) -> TOMLTable {
        while true {
            scanner.skipInsignificant()
            guard let next = scanner.peek() else { break }
            if next == "[" {
                try header()
            } else {
                try keyValue()
            }
        }
        return root
    }

    // MARK: - Structure

    private mutating func header() throws(TOMLParseError) {
        let headerLine = scanner.line
        try scanner.expect("[")
        let isArray = scanner.peek() == "["
        if isArray { scanner.advance() }

        scanner.skipBlanks()
        let path = try keyPath()
        scanner.skipBlanks()
        try scanner.expect("]")
        if isArray { try scanner.expect("]") }
        try scanner.endOfLine()

        let joined = path.joined(separator: ".")
        if isArray {
            try appendArrayOfTables(at: path, line: headerLine)
        } else {
            guard declaredTables.insert(joined).inserted else {
                throw scanner.failure("the table '\(joined)' was already declared", at: headerLine)
            }
            try declareTable(at: path, line: headerLine)
        }
        currentPath = path
    }

    private mutating func declareTable(at path: [String], line: Int) throws(TOMLParseError) {
        let leaf = path[path.count - 1]
        try mutateTable(at: Array(path.dropLast()), line: line) { parent in
            if parent[leaf] == nil {
                _ = parent.insert(leaf, .table(TOMLTable()), at: line)
            }
        }
    }

    private mutating func appendArrayOfTables(at path: [String], line: Int) throws(TOMLParseError) {
        let leaf = path[path.count - 1]
        try mutateTable(at: Array(path.dropLast()), line: line) { parent in
            var rows = parent[leaf]?.array ?? []
            rows.append(.table(TOMLTable()))
            if parent[leaf] == nil {
                _ = parent.insert(leaf, .array(rows), at: line)
            } else {
                parent.replace(leaf, with: .array(rows))
            }
        }
    }

    private mutating func keyValue() throws(TOMLParseError) {
        let keyLine = scanner.line
        let path = try keyPath()
        scanner.skipBlanks()
        try scanner.expect("=")
        scanner.skipBlanks()
        let value = try self.value()
        try scanner.endOfLine()

        let leaf = path[path.count - 1]
        var duplicated = false
        try mutateTable(at: currentPath + Array(path.dropLast()), line: keyLine) { table in
            duplicated = !table.insert(leaf, value, at: keyLine)
        }
        if duplicated {
            throw scanner.failure("the key '\(leaf)' was already given a value", at: keyLine)
        }
    }

    /// Applies a change to the table at a path, creating the tables along the way.
    ///
    /// An array of tables is navigated into its last row, which is what makes a `[[a.b]]`
    /// header followed by keys write into the row that header just added.
    private mutating func mutateTable(
        at path: [String],
        line: Int,
        _ change: (inout TOMLTable) -> Void
    ) throws(TOMLParseError) {
        func descend(
            _ table: inout TOMLTable,
            _ remaining: ArraySlice<String>
        ) throws(TOMLParseError) {
            guard let step = remaining.first else {
                change(&table)
                return
            }
            let rest = remaining.dropFirst()
            switch table[step] {
            case .table(var child):
                try descend(&child, rest)
                table.replace(step, with: .table(child))
            case .array(var rows):
                guard case .table(var last)? = rows.last else {
                    throw scanner.failure(
                        "'\(step)' is an array of values, not an array of tables",
                        at: line
                    )
                }
                try descend(&last, rest)
                rows[rows.count - 1] = .table(last)
                table.replace(step, with: .array(rows))
            case .some(let existing):
                throw scanner.failure(
                    "'\(step)' is \(existing.kind), so it cannot also be a table",
                    at: line
                )
            case nil:
                var child = TOMLTable()
                try descend(&child, rest)
                _ = table.insert(step, .table(child), at: line)
            }
        }
        try descend(&root, path[...])
    }

    // MARK: - Keys and values

    private mutating func keyPath() throws(TOMLParseError) -> [String] {
        var path = [try key()]
        while scanner.peek() == "." {
            scanner.advance()
            scanner.skipBlanks()
            path.append(try key())
        }
        return path
    }

    private mutating func key() throws(TOMLParseError) -> String {
        scanner.skipBlanks()
        if scanner.peek() == "\"" { return try basicString() }
        if scanner.peek() == "'" { return try literalString() }
        var name = ""
        while let next = scanner.peek(),
            next.isLetter || next.isNumber || next == "_" || next == "-"
        {
            name.append(next)
            scanner.advance()
        }
        guard !name.isEmpty else { throw scanner.failure("expected a key") }
        return name
    }

    private mutating func value() throws(TOMLParseError) -> TOMLValue {
        guard let next = scanner.peek() else { throw scanner.failure("expected a value") }
        switch next {
        case "\"": return .string(try basicString())
        case "'": return .string(try literalString())
        case "[": return .array(try array())
        case "{":
            throw scanner.failure("an inline table is not part of a swift-mutants configuration")
        case "t", "f": return .boolean(try boolean())
        default:
            guard next == "-" || next == "+" || next.isNumber else {
                throw scanner.failure("expected a value")
            }
            return .integer(try integer())
        }
    }

    private mutating func array() throws(TOMLParseError) -> [TOMLValue] {
        try scanner.expect("[")
        var elements: [TOMLValue] = []
        while true {
            scanner.skipInsignificant()
            if scanner.peek() == "]" {
                scanner.advance()
                return elements
            }
            guard scanner.peek() != nil else {
                throw scanner.failure("expected ']' to close the array")
            }
            elements.append(try value())
            scanner.skipInsignificant()
            if scanner.peek() == "," {
                scanner.advance()
                continue
            }
            if scanner.peek() == "]" { continue }
            throw scanner.failure("expected ',' or ']' in the array")
        }
    }

    private mutating func boolean() throws(TOMLParseError) -> Bool {
        if scanner.matches("true") { return true }
        if scanner.matches("false") { return false }
        throw scanner.failure("expected a value")
    }

    private mutating func integer() throws(TOMLParseError) -> Int {
        var text = ""
        if scanner.peek() == "-" || scanner.peek() == "+" {
            text.append(scanner.advance() ?? "+")
        }
        while let next = scanner.peek(), next.isNumber || next == "_" {
            if next != "_" { text.append(next) }
            scanner.advance()
        }
        guard !text.isEmpty, text != "-", text != "+" else {
            throw scanner.failure("expected a value")
        }
        if let next = scanner.peek(), let refusal = Self.refusals[next] {
            throw scanner.failure("\(refusal) is not part of a swift-mutants configuration")
        }
        guard let number = Int(text) else {
            throw scanner.failure("'\(text)' does not fit in an integer")
        }
        return number
    }

    /// What a run of digits can turn into that this grammar does not hold.
    ///
    /// Named rather than merely rejected, because "expected the end of the line" after
    /// `3.14` sends a reader looking at the wrong thing.
    private static let refusals: [Character: String] = [
        ".": "a floating-point number", "e": "a floating-point number",
        "E": "a floating-point number", "-": "a date", ":": "a date", "T": "a date",
        "Z": "a date", "x": "only decimal integers are", "o": "only decimal integers are",
        "b": "only decimal integers are",
    ]

    private mutating func basicString() throws(TOMLParseError) -> String {
        try scanner.expect("\"")
        var text = ""
        while let next = scanner.advance() {
            switch next {
            case "\"": return text
            case "\n": throw scanner.failure("a string cannot span lines")
            case "\\":
                guard let escape = scanner.advance() else {
                    throw scanner.failure("expected an escape")
                }
                guard let replacement = Self.escapes[escape] else {
                    throw scanner.failure("'\\\(escape)' is not an escape this reader knows")
                }
                text.append(replacement)
            default: text.append(next)
            }
        }
        throw scanner.failure("expected '\"' to close the string")
    }

    private mutating func literalString() throws(TOMLParseError) -> String {
        try scanner.expect("'")
        var text = ""
        while let next = scanner.advance() {
            if next == "'" { return text }
            if next == "\n" { throw scanner.failure("a string cannot span lines") }
            text.append(next)
        }
        throw scanner.failure("expected \"'\" to close the string")
    }

    /// The escapes a basic string may contain.
    ///
    /// A short table on purpose: every escape is another thing that can be written two
    /// ways, and a configuration has no need for the Unicode forms.
    private static let escapes: [Character: Character] = [
        "n": "\n", "t": "\t", "r": "\r", "\"": "\"", "\\": "\\", "0": "\0",
    ]
}
