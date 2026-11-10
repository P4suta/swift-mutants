// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutants

@Suite("XCTest completion properties")
struct XCTestTranscriptPropertyTests {
    @Test("completion multisets reconcile both XML skip representations")
    func generatedCompletions() throws {
        for seed in 0..<27 {
            let statuses = (0..<3).map { seed / Self.powerOfThree($0) % 3 }
            for declaredSkips in [false, true] {
                var expected = XUnitResults()
                var raw = XUnitResults()
                var lines: [String] = []
                for (index, status) in statuses.enumerated() {
                    let identity = TestIdentity(
                        framework: "Fixture:xctest", className: "Suite", name: "test\(index % 2)")
                    if status == 2 {
                        expected.skipped[identity, default: 0] += 1
                    } else {
                        expected.executed[identity, default: 0] += 1
                    }
                    if status == 2 && declaredSkips {
                        raw.skipped[identity, default: 0] += 1
                    } else {
                        raw.executed[identity, default: 0] += 1
                    }
                    if status == 1 { expected.failures += 1; raw.failures += 1 }
                    let name = ["passed", "failed", "skipped"][status]
                    lines.append("Test Case '-[Suite \(identity.name)]' \(name) (0.001 seconds).")
                }
                try XCTestTranscript.reconcile(
                    &raw,
                    output: lines.reversed().joined(separator: "\n"),
                    framework: "Fixture:xctest")
                #expect(raw == expected, "seed=\(seed), declaredSkips=\(declaredSkips)")
            }
        }
    }

    @Test(
        "missing, extra, repeated, and contradictory completions are rejected",
        arguments: ["missing", "extra", "repeated", "failure", "declared-skip"]
    )
    func inconsistentCompletions(kind: String) {
        let identity = TestIdentity(framework: "Fixture:xctest", className: "Suite", name: "test")
        var raw = XUnitResults(executed: [identity: 1])
        let passed = "Test Case '-[Suite test]' passed (0.001 seconds)."
        let output: String
        switch kind {
        case "missing": output = "Test Case '-[Suite test]' started."
        case "extra": output = passed + "\nTest Case '-[Suite extra]' passed (0.001 seconds)."
        case "repeated": output = passed + "\n" + passed
        case "failure": output = "Test Case '-[Suite test]' failed (0.001 seconds)."
        default:
            raw = XUnitResults(skipped: [identity: 1])
            output = passed
        }
        #expect(throws: XUnitError.self) {
            try XCTestTranscript.reconcile(&raw, output: output, framework: "Fixture:xctest")
        }
    }

    private static func powerOfThree(_ exponent: Int) -> Int {
        (0..<exponent).reduce(1) { value, _ in value * 3 }
    }
}
