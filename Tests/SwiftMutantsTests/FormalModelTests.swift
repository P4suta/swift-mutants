// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutants

@Suite("Measurement model correspondence")
struct FormalModelTests {
    @Test("Swift agrees with every checked observation class")
    func verdicts() throws {
        let rows = try Self.rows(
            "verdicts.csv", header: "timedOut,trustworthy,inventory,failed,verdict,outcome"
        )
        var seen: Set<String> = []
        var verdicts: Set<String> = []
        for row in rows {
            try #require(row.count == 6)
            let inventory = try #require(TestInventory(rawValue: String(row[2])))
            let verdict = TestVerdict.classify(
                timedOut: try Self.bool(row[0]),
                trustworthy: try Self.bool(row[1]),
                inventory: inventory,
                failed: try Self.bool(row[3])
            )
            #expect(verdict.rawValue == row[4])
            #expect(verdict.outcome.rawValue == row[5])
            let incomplete = row[5] == "errored" || row[5] == "timedOut"
            #expect((verdict.diagnostic != nil) == incomplete)
            try Self.observation(row, inventory: inventory)
            seen.insert(row.prefix(4).joined(separator: ","))
            verdicts.insert(String(row[4]))
        }
        let count = 2 * 2 * TestInventory.allCases.count * 2
        #expect(rows.count == count)
        #expect(seen.count == count)
        #expect(verdicts == Set(TestVerdict.allCases.map(\.rawValue)))
    }

    @Test("Swift scores agree with every checked presence class")
    func scores() throws {
        let rows = try Self.rows(
            "scores.csv", header: "killed,survived,rejected,timedOut,errored,numerator,denominator"
        )
        let mutation = try Self.mutation()
        var seen: Set<String> = []
        for row in rows {
            try #require(row.count == 7)
            let outcomes: [MutationOutcome] = [.killed, .survived, .rejected, .timedOut, .errored]
            #expect(Set(outcomes) == Set(MutationOutcome.allCases))
            let results = try zip(outcomes, row.prefix(5)).compactMap { outcome, present in
                try Self.bool(present) ? MutationResult(mutation: mutation, outcome: outcome) : nil
            }
            let report = MutationReport(results: results)
            if row[5] == "nil" {
                #expect(row[6] == "nil")
                #expect(report.score == nil)
            } else {
                let numerator = try #require(Double(row[5]))
                let denominator = try #require(Double(row[6]))
                try #require(denominator > 0)
                #expect(report.score == numerator / denominator)
            }
            seen.insert(row.prefix(5).joined(separator: ","))
        }
        #expect(rows.count == 32)
        #expect(seen.count == 32)
    }

    @Test("outcome counts partition reports across generated multiplicities")
    func partitions() throws {
        let mutation = try Self.mutation()
        try #require(MutationOutcome.allCases.count == 5)
        for seed in 0..<1_024 {
            let counts = MutationOutcome.allCases.enumerated().map { index, outcome in
                (outcome, (seed >> (index * 2)) & 3)
            }
            let results = counts.flatMap { outcome, count in
                Array(repeating: MutationResult(mutation: mutation, outcome: outcome), count: count)
            }
            let report = MutationReport(results: results)
            let expected = Dictionary(uniqueKeysWithValues: counts)
            #expect(report.summary.total == results.count)
            #expect(report.summary.killed == expected[.killed])
            #expect(report.summary.survived == expected[.survived])
            #expect(report.summary.rejected == expected[.rejected])
            #expect(report.summary.timedOut == expected[.timedOut])
            #expect(report.summary.errored == expected[.errored])
        }
    }

    private static func bool(_ value: Substring) throws -> Bool {
        try #require(value == "0" || value == "1")
        return value == "1"
    }

    private static func observation(_ row: [Substring], inventory: TestInventory) throws {
        let original = TestIdentity(framework: "fixture", className: "Suite", name: "original")
        let extra = TestIdentity(framework: "fixture", className: "Suite", name: "extra")
        let baseline = XUnitResults(executed: [original: 1])
        for diagnosticFailure in [false, true] {
            var results = baseline
            if inventory == .empty { results.executed = [:] }
            if inventory == .changed { results.executed[extra] = 1 }
            results.failures = try bool(row[3]) ? 1 : 0
            let trustworthy = try bool(row[1])
            if !trustworthy && !diagnosticFailure { results.errors = 1 }
            let observation = TestObservation(
                results: results,
                timedOut: try bool(row[0]),
                diagnostic: !trustworthy && diagnosticFailure ? "fixture diagnostic" : nil
            )
            #expect(observation.verdict(comparedTo: baseline).rawValue == row[4])
        }
    }

    private static func mutation() throws -> Mutation {
        try #require(
            Mutation.discover(in: "func value() -> Bool { true }", at: "Value.swift").first)
    }

    private static func rows(_ name: String, header: String) throws -> [[Substring]] {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "Proofs/\(name)"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        try #require(lines.first == Substring(header))
        return lines.dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
    }
}
