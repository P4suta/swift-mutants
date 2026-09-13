// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore

/// The typed reads a configuration decoder makes, each able to say where it was reading.
///
/// Separated from the decoder because the decoder is about what the fields *mean* and this
/// is about what a value *is*. Every refusal carries the line the value was written on,
/// which is the whole reason the parser remembers positions.
enum Reader {

    /// Refuses any key the tool does not know, naming it and where it is.
    ///
    /// This is the check that earns the parser's bookkeeping. The commonest mistake a
    /// configuration contains is a key nobody meant to write - a typo, or a setting copied
    /// from another tool - and a decoder that ignored it would let a project believe the
    /// setting had been in effect ever since.
    static func refuseUnknownKeys(
        in table: TOMLTable,
        known: Set<String>,
        path: String
    ) throws(ConfigurationError) {
        for key in table.keys where !known.contains(key) {
            let qualified = path.isEmpty ? key : "\(path).\(key)"
            throw ConfigurationError(
                line: table.line(of: key) ?? 0,
                reason:
                    "'\(qualified)' is not a setting this tool knows. Its neighbours are: "
                    + known.sorted().joined(separator: ", ")
            )
        }
    }

    static func table(_ parent: TOMLTable, _ key: String) throws(ConfigurationError) -> TOMLTable? {
        guard let value = parent[key] else { return nil }
        guard let table = value.table else {
            throw mismatch(key, key, parent, "a table", value)
        }
        return table
    }

    static func string(
        _ value: TOMLValue,
        _ key: String,
        in table: TOMLTable,
        path: String
    ) throws(ConfigurationError) -> String {
        guard let text = value.string else {
            throw mismatch(qualify(path, key), key, table, "a string", value)
        }
        return text
    }

    static func boolean(
        _ value: TOMLValue,
        _ key: String,
        in table: TOMLTable,
        path: String
    ) throws(ConfigurationError) -> Bool {
        guard let flag = value.boolean else {
            throw mismatch(qualify(path, key), key, table, "a boolean", value)
        }
        return flag
    }

    static func integer(
        _ value: TOMLValue,
        _ key: String,
        in table: TOMLTable
    ) throws(ConfigurationError) -> Int {
        guard let number = value.integer else {
            throw mismatch(key, key, table, "an integer", value)
        }
        return number
    }

    static func optionalInteger(
        _ table: TOMLTable,
        _ key: String,
        path: String
    ) throws(ConfigurationError) -> Int? {
        guard let value = table[key] else { return nil }
        guard let number = value.integer else {
            throw mismatch(qualify(path, key), key, table, "an integer", value)
        }
        return number
    }

    static func strings(
        _ table: TOMLTable,
        _ key: String,
        path: String
    ) throws(ConfigurationError) -> [String] {
        guard let value = table[key] else { return [] }
        guard let elements = value.array else {
            throw mismatch(qualify(path, key), key, table, "an array of strings", value)
        }
        var texts: [String] = []
        for element in elements {
            guard let text = element.string else {
                throw mismatch(qualify(path, key), key, table, "an array of strings", element)
            }
            texts.append(text)
        }
        return texts
    }

    static func globs(
        _ table: TOMLTable,
        _ key: String,
        path: String
    ) throws(ConfigurationError) -> [Glob] {
        var globs: [Glob] = []
        for pattern in try strings(table, key, path: path) {
            guard let glob = Glob(pattern) else {
                throw ConfigurationError(
                    line: table.line(of: key) ?? 0,
                    reason:
                        "'\(pattern)' is not a pattern: '**' is a whole path component, and a "
                        + "pattern has to name something"
                )
            }
            globs.append(glob)
        }
        return globs
    }

    static func enumerated<T: RawRepresentable & CaseIterable>(
        _ value: TOMLValue,
        _ key: String,
        in table: TOMLTable,
        path: String
    ) throws(ConfigurationError) -> T where T.RawValue == String {
        let text = try string(value, key, in: table, path: path)
        guard let choice = T(rawValue: text) else {
            let choices = T.allCases.map(\.rawValue).sorted().joined(separator: ", ")
            throw ConfigurationError(
                line: table.line(of: key) ?? 0,
                reason: "'\(text)' is not one of: \(choices)"
            )
        }
        return choice
    }

    /// Reads `"90s"`, `"500ms"`, `"2m"`, `"1h"`.
    static func duration(
        _ value: TOMLValue,
        _ key: String,
        in table: TOMLTable,
        path: String
    ) throws(ConfigurationError) -> Duration {
        let text = try string(value, key, in: table, path: path)
        for (suffix, scale) in Self.durationUnits where text.hasSuffix(suffix) {
            let digits = text.dropLast(suffix.count)
            if let amount = Int(digits), amount >= 0 {
                return .milliseconds(amount * scale)
            }
        }
        throw ConfigurationError(
            line: table.line(of: key) ?? 0,
            reason:
                "'\(text)' is not a duration. Write one as a whole number and a unit: "
                + "500ms, 90s, 2m, 1h"
        )
    }

    /// Longest suffix first, so `ms` is never read as `s`.
    private static let durationUnits: [(String, Int)] = [
        ("ms", 1), ("s", 1000), ("m", 60_000), ("h", 3_600_000),
    ]

    /// Reads `"512B"`, `"2KiB"`, `"3MiB"`, `"2GiB"`.
    ///
    /// Binary units only. A bound that reads as two gigabytes and is quietly seven per cent
    /// tighter is a bound nobody can reason about, so `GB` is refused rather than
    /// reinterpreted as `GiB`.
    static func byteSize(
        _ value: TOMLValue,
        _ key: String,
        in table: TOMLTable,
        path: String
    ) throws(ConfigurationError) -> Int {
        let text = try string(value, key, in: table, path: path)
        for (suffix, scale) in Self.byteUnits where text.hasSuffix(suffix) {
            let digits = text.dropLast(suffix.count)
            if let amount = Int(digits), amount >= 0 {
                return amount * scale
            }
        }
        throw ConfigurationError(
            line: table.line(of: key) ?? 0,
            reason:
                "'\(text)' is not a size. Write one with a binary unit: B, KiB, MiB, GiB, TiB. "
                + "The decimal spellings are refused rather than reinterpreted, so that a "
                + "bound is never quietly smaller than it reads"
        )
    }

    /// Longest suffix first, so `KiB` is never read as `B`.
    private static let byteUnits: [(String, Int)] = [
        ("TiB", 1 << 40), ("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10), ("B", 1),
    ]

    /// Reads `[[mutation.expect]]`.
    static func expectations(
        _ table: TOMLTable
    ) throws(ConfigurationError) -> [Configuration.Expectation] {
        guard let rows = table["expect"]?.array else { return [] }
        let line = table.line(of: "expect") ?? 0
        var seen: Set<String> = []
        var expectations: [Configuration.Expectation] = []

        for row in rows {
            guard let fields = row.table else {
                throw ConfigurationError(
                    line: line,
                    reason: "mutation.expect is written as [[mutation.expect]] tables"
                )
            }
            try refuseUnknownKeys(in: fields, known: ["id", "reason"], path: "mutation.expect")
            let rowLine = fields.line(of: "id") ?? line
            guard let identity = fields["id"]?.string else {
                throw ConfigurationError(line: rowLine, reason: "mutation.expect needs an 'id'")
            }
            guard identity.count == 64, identity.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                throw ConfigurationError(
                    line: rowLine,
                    reason:
                        "'\(identity)' is not a mutant identity: it is 64 lowercase hexadecimal "
                        + "characters, which `swift-mutants list --json` prints in full"
                )
            }
            guard let reason = fields["reason"]?.string, !reason.isEmpty else {
                throw ConfigurationError(
                    line: fields.line(of: "reason") ?? rowLine,
                    reason:
                        "an expectation needs a non-empty 'reason': it is evidence to check, "
                        + "and the next reader has to know what was being claimed"
                )
            }
            guard seen.insert(identity).inserted else {
                throw ConfigurationError(
                    line: rowLine,
                    reason: "there are two expectations about the mutant \(identity)"
                )
            }
            expectations.append(
                Configuration.Expectation(identity: identity, reason: reason)
            )
        }
        return expectations
    }

    private static func qualify(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    private static func mismatch(
        _ qualified: String,
        _ key: String,
        _ table: TOMLTable,
        _ expected: String,
        _ found: TOMLValue
    ) -> ConfigurationError {
        ConfigurationError(
            line: table.line(of: key) ?? 0,
            reason: "'\(qualified)' is \(expected); this is \(found.kind)"
        )
    }
}
