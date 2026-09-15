// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore

/// Reads a ``Configuration`` out of a parsed document, strictly.
///
/// Strict in both directions. A key this tool does not know is refused with the line it was
/// written on, because a decoder that ignored one would let a project believe a setting had
/// been in effect for months. A value of the wrong shape is refused the same way, naming
/// what was expected and what was found.
extension Configuration {

    /// Reads a configuration, or says what is wrong with it and where.
    public init(_ document: TOMLTable) throws(ConfigurationError) {
        self.init()

        if let version = document["version"] {
            let number = try Reader.integer(version, "version", in: document)
            guard number == Self.version else {
                throw ConfigurationError(
                    line: document.line(of: "version") ?? 0,
                    reason:
                        "this build reads version \(Self.version) of the configuration format, not \(number)"
                )
            }
        }

        try Reader.refuseUnknownKeys(
            in: document,
            known: ["version", "mutation", "test", "execution", "cache", "policy", "report"],
            path: ""
        )

        if let table = try Reader.table(document, "mutation") {
            try readMutation(table)
        }
        if let table = try Reader.table(document, "test") {
            try readTest(table)
        }
        if let table = try Reader.table(document, "execution") {
            try Reader.refuseUnknownKeys(in: table, known: ["jobs"], path: "execution")
            execution.jobs = try Reader.optionalInteger(table, "jobs", path: "execution")
        }
        if let table = try Reader.table(document, "cache") {
            try Reader.refuseUnknownKeys(in: table, known: ["mode"], path: "cache")
            if let mode = table["mode"] {
                cache.mode = try Reader.enumerated(mode, "mode", in: table, path: "cache")
            }
        }
        if let table = try Reader.table(document, "policy") {
            try readPolicy(table)
        }
        if let table = try Reader.table(document, "report") {
            try readReport(table)
        }
    }

    private mutating func readMutation(_ table: TOMLTable) throws(ConfigurationError) {
        try Reader.refuseUnknownKeys(
            in: table,
            known: [
                "profile", "extreme", "include", "exclude", "operators", "expect", "custom",
            ],
            path: "mutation"
        )
        if let profile = table["profile"] {
            mutation.profile = try Reader.enumerated(
                profile, "profile", in: table, path: "mutation")
        }
        if let extreme = table["extreme"] {
            mutation.extreme = try Reader.boolean(extreme, "extreme", in: table, path: "mutation")
        }
        mutation.include = try Reader.globs(table, "include", path: "mutation")
        mutation.exclude = try Reader.globs(table, "exclude", path: "mutation")
        mutation.operators = try Reader.strings(table, "operators", path: "mutation")
        mutation.expect = try Reader.expectations(table)
        mutation.custom = try Reader.customMutants(table)
    }

    private mutating func readTest(_ table: TOMLTable) throws(ConfigurationError) {
        try Reader.refuseUnknownKeys(
            in: table,
            known: ["command", "timeout", "memory", "baseline_runs"],
            path: "test"
        )
        if table["command"] != nil {
            let command = try Reader.strings(table, "command", path: "test")
            guard !command.isEmpty else {
                throw ConfigurationError(
                    line: table.line(of: "command") ?? 0,
                    reason: "test.command names no program"
                )
            }
            test.command = command
        }
        if let timeout = table["timeout"] {
            test.timeout = try Reader.duration(timeout, "timeout", in: table, path: "test")
        }
        if let memory = table["memory"] {
            test.memoryBytes = try Reader.byteSize(memory, "memory", in: table, path: "test")
        }
        if let runs = try Reader.optionalInteger(table, "baseline_runs", path: "test") {
            guard runs >= 1 else {
                throw ConfigurationError(
                    line: table.line(of: "baseline_runs") ?? 0,
                    reason: "test.baseline_runs measures the baseline at least once"
                )
            }
            test.baselineRuns = runs
        }
    }

    private mutating func readPolicy(_ table: TOMLTable) throws(ConfigurationError) {
        try Reader.refuseUnknownKeys(in: table, known: ["strict", "minimum_score"], path: "policy")
        if let strict = table["strict"] {
            policy.strict = try Reader.boolean(strict, "strict", in: table, path: "policy")
        }
        if let score = try Reader.optionalInteger(table, "minimum_score", path: "policy") {
            guard (0...100).contains(score) else {
                throw ConfigurationError(
                    line: table.line(of: "minimum_score") ?? 0,
                    reason: "policy.minimum_score is a percentage, so it lies between 0 and 100"
                )
            }
            policy.minimumScore = score
        }
    }

    private mutating func readReport(_ table: TOMLTable) throws(ConfigurationError) {
        try Reader.refuseUnknownKeys(
            in: table,
            known: ["directory", "formats", "high", "low"],
            path: "report"
        )
        if let directory = table["directory"] {
            report.directory = try Reader.string(directory, "directory", in: table, path: "report")
        }
        if let formats = table["formats"]?.array {
            var chosen: [ReportFormat] = []
            for value in formats {
                chosen.append(try Reader.enumerated(value, "formats", in: table, path: "report"))
            }
            report.formats = chosen
        }
        if let high = try Reader.optionalInteger(table, "high", path: "report") {
            report.high = high
        }
        if let low = try Reader.optionalInteger(table, "low", path: "report") {
            report.low = low
        }
    }
}
