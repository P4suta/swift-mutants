// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A value a `.swift-mutants.toml` can hold.
///
/// The cases are the whole of the supported grammar. There is no floating-point case and no
/// date case because a configuration has no use for either, and a value that parses into
/// something the reader did not mean is worse than one that does not parse.
public enum TOMLValue: Sendable, Hashable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([Self])
    case table(TOMLTable)

    /// The string, if this is one.
    public var string: String? { if case .string(let value) = self { value } else { nil } }

    /// The integer, if this is one.
    public var integer: Int? { if case .integer(let value) = self { value } else { nil } }

    /// The boolean, if this is one.
    public var boolean: Bool? { if case .boolean(let value) = self { value } else { nil } }

    /// The elements, if this is an array.
    public var array: [Self]? { if case .array(let value) = self { value } else { nil } }

    /// The table, if this is one.
    public var table: TOMLTable? { if case .table(let value) = self { value } else { nil } }

    /// What this value is, for a message that has to name it.
    public var kind: String {
        switch self {
        case .string: "a string"
        case .integer: "an integer"
        case .boolean: "a boolean"
        case .array: "an array"
        case .table: "a table"
        }
    }
}

/// A table, remembering where each of its keys was written.
///
/// The positions are the point. The commonest mistake a configuration file contains is a
/// key nobody meant to write - a typo, or a setting from a different tool - and reporting
/// it as "unknown key 'profil' at line 7" rather than as "could not decode" is the
/// difference between a fix and a bisection.
public struct TOMLTable: Sendable, Hashable {

    private var storage: [String: TOMLValue] = [:]
    private var lines: [String: Int] = [:]
    private var order: [String] = []

    /// Creates an empty table.
    public init() {}

    /// The value for a key.
    public subscript(key: String) -> TOMLValue? { storage[key] }

    /// The keys, in the order they were written.
    public var keys: [String] { order }

    /// Whether the table holds nothing.
    public var isEmpty: Bool { order.isEmpty }

    /// The line a key was written on.
    public func line(of key: String) -> Int? { lines[key] }

    /// Records a key, or reports that it was already there.
    mutating func insert(_ key: String, _ value: TOMLValue, at line: Int) -> Bool {
        guard storage[key] == nil else { return false }
        storage[key] = value
        lines[key] = line
        order.append(key)
        return true
    }

    /// Replaces a key that is already there, keeping its position.
    mutating func replace(_ key: String, with value: TOMLValue) {
        guard storage[key] != nil else { return }
        storage[key] = value
    }
}

/// A configuration this tool could not read, and where it stopped.
public struct TOMLParseError: Error, Hashable, CustomStringConvertible {

    /// The line the parser stopped on, counting from one the way a reader does.
    public let line: Int

    /// The column it stopped at, counting from one.
    public let column: Int

    /// What went wrong, in the words a fix needs.
    public let reason: String

    /// The failure with its position, ready to print.
    public var description: String { "line \(line), column \(column): \(reason)" }

    init(line: Int, column: Int, reason: String) {
        self.line = line
        self.column = column
        self.reason = reason
    }
}
