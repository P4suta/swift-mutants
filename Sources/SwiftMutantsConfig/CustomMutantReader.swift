// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Reading the mutants a project wrote for itself.
///
/// Its own file because it is its own subject: everything else the reader handles is a
/// setting, and these are data a project accumulates and refactors around.
extension Reader {

    /// Reads `[[mutation.custom]]`.
    ///
    /// Anchored by text rather than by position, because a position moves whenever anything
    /// above it does and a project would be rewriting its catalogue after every edit. An
    /// optional `line` is there for the case where the text appears more than once - though
    /// somebody with 290 of these by hand reports never having needed one, because when an
    /// anchor is ambiguous the fix they wanted was a longer anchor, which is a better row.
    static func customMutants(
        _ table: TOMLTable
    ) throws(ConfigurationError) -> [Configuration.Custom] {
        guard let rows = table["custom"]?.array else { return [] }
        let line = table.line(of: "custom") ?? 0
        var seen: Set<Configuration.Custom> = []
        var custom: [Configuration.Custom] = []

        for row in rows {
            guard let fields = row.table else {
                throw ConfigurationError(
                    line: line,
                    reason: "mutation.custom is written as [[mutation.custom]] tables"
                )
            }
            try refuseUnknownKeys(
                in: fields,
                known: ["file", "find", "replace", "reason", "line"],
                path: "mutation.custom"
            )
            let rowLine = fields.line(of: "file") ?? line
            let one = try Self.customMutant(fields, at: rowLine)
            guard seen.insert(one).inserted else {
                throw ConfigurationError(
                    line: rowLine,
                    reason: """
                        there are two identical mutation.custom rows. Two rows may name one \
                        place when they replace it differently - that is two questions - but \
                        two rows the same in every field is one question written twice.
                        """
                )
            }
            custom.append(one)
        }
        return custom
    }

    /// One row of `[[mutation.custom]]`, or the reason it is not one.
    private static func customMutant(
        _ fields: TOMLTable, at rowLine: Int
    ) throws(ConfigurationError) -> Configuration.Custom {
        let file = try Self.required(fields, "file", at: rowLine)
        let find = try Self.required(fields, "find", at: rowLine)
        let reason = try Self.required(fields, "reason", at: rowLine)
        guard let replace = fields["replace"]?.string else {
            throw ConfigurationError(
                line: fields.line(of: "replace") ?? rowLine,
                reason: "a mutation.custom row needs a 'replace', which may be empty"
            )
        }
        guard replace != find else {
            throw ConfigurationError(
                line: fields.line(of: "replace") ?? rowLine,
                reason: """
                    this mutation.custom row replaces \"\(find)\" with itself, so it changes \
                    nothing - and a mutant that changes nothing survives every suite there \
                    will ever be
                    """
            )
        }
        var found = Configuration.Custom(
            file: file, find: find, replace: replace, reason: reason)
        if let written = fields["line"] {
            let number = try Self.integer(written, "line", in: fields)
            guard number > 0 else {
                throw ConfigurationError(
                    line: fields.line(of: "line") ?? rowLine,
                    reason: "a line is counted from one, and \(number) is not a line"
                )
            }
            found.line = number
        }
        return found
    }

    /// A field a row cannot do without, or the reason it is missing.
    private static func required(
        _ fields: TOMLTable, _ key: String, at rowLine: Int
    ) throws(ConfigurationError) -> String {
        guard let value = fields[key]?.string, !value.isEmpty else {
            throw ConfigurationError(
                line: fields.line(of: key) ?? rowLine,
                reason: "a mutation.custom row needs a non-empty '\(key)'"
            )
        }
        return value
    }
}
