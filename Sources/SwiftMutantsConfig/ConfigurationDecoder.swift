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
            // Refused rather than accepted and ignored. Whole-body replacement is not in
            // this build, and a setting that is read, validated, stored and then honoured
            // by nothing gives a project exactly the run they would have had without it -
            // with no way to find that out short of reading this tool's source.
            //
            // `false` is accepted, because that is what this build does. Saying no to a
            // request for nothing would be pedantry rather than honesty.
            guard !mutation.extreme else {
                throw ConfigurationError(
                    line: table.line(of: "extreme") ?? 0,
                    reason: """
                        `extreme` asks for whole function bodies to be replaced, which this \
                        build does not do. It is refused rather than ignored so that a run \
                        is never quietly narrower than the settings say. Remove the line, \
                        or set it to false.
                        """
                )
            }
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
            // Refused rather than accepted and ignored, and refused before the value is
            // read, for the same reason as `memory`: the key is not supported, so
            // complaining about the shape of its value first would send somebody to correct
            // a list that was never going to be used.
            //
            // Refused rather than accepted and ignored. A run builds the test bundles once
            // and launches them directly for every mutant - that is what makes one build
            // serve a whole catalogue - so there is no point at which a different program
            // could be run, and pretending to take one would give a project exactly the
            // run they would have had without it.
            //
            // Arguments are a different thing and do work: everything after `--` reaches
            // the tests verbatim, and narrows what the score is about in the same way.
            throw ConfigurationError(
                line: table.line(of: "command") ?? 0,
                reason: """
                    `test.command` names a program to run the tests with, which this build \
                    cannot do: it builds your test bundles once and launches them directly, \
                    which is what makes one build serve every mutant. Pass arguments to your \
                    tests after `--` instead, which reaches them verbatim.
                    """
            )
        }
        if let timeout = table["timeout"] {
            test.timeout = try Reader.duration(timeout, "timeout", in: table, path: "test")
        }
        if table["memory"] != nil {
            // Refused rather than accepted and ignored, and refused before the size is
            // read: the key is not supported, so complaining about the shape of its value
            // first would send somebody to correct a number that was never going to be
            // used.
            //
            // Nothing here bounds a mutant by memory, and a limit that is stored and never
            // applied is worse than none: it reads as a guard against the mutant that turns
            // a loop into one that does not end, which is exactly the case it is set for.
            //
            // Not an oversight that can be fixed by wiring it up. Measured on this
            // platform: under `ulimit -v 262144`, `ulimit -v` reports `unlimited` and a
            // process allocates four gigabytes unhindered, so the obvious enforcement does
            // not enforce. The bound that does work is the processor allowance, which the
            // kernel does apply and which a busy machine cannot move.
            throw ConfigurationError(
                line: table.line(of: "memory") ?? 0,
                reason: """
                    `test.memory` bounds a mutant by memory, which this build does not do: \
                    macOS does not apply the address-space limit it would need. It is \
                    refused rather than ignored, because a limit nothing enforces reads as a \
                    guard you do not have. A mutant is bounded by the processor time it \
                    uses, which the kernel does enforce; `timeout` sets that.
                    """
            )
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
