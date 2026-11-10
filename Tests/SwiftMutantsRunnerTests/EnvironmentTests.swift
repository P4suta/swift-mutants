// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsRunner

@Suite("Exact subprocess environments")
struct EnvironmentTests {
    @Test(
        "environment values preserve every byte across allocation boundaries",
        arguments: ["", "=\u{00E9}\u{1F600}"])
    func roundTrips(suffix: String) async throws {
        let key = "SWIFT_MUTANTS_ACTIVE"
        let runner = Runner(recorder: TraceRecorder())
        for length in stride(from: 128, through: 0, by: -1) {
            let value = String(repeating: "x", count: length) + suffix
            let outcome = await runner.run(
                ProcessSpec(
                    kind: .testFixture,
                    executable: "/usr/bin/printenv",
                    arguments: [key],
                    directory: FileManager.default.temporaryDirectory.path,
                    environment: [key: value],
                    timeout: .seconds(5)))
            try #require(outcome.exitCode == 0)
            try #require(outcome.standardOutputText == value + "\n", "length=\(length)")
        }
    }

    @Test("activation values round-trip at decimal and integer boundaries")
    func activation() async throws {
        let key = "SWIFT_MUTANTS_ACTIVE"
        let runner = Runner(recorder: TraceRecorder())
        for value in ["0", "1", "9", "10", "99", "100", "255", "256", "4294967295"] {
            let outcome = await runner.run(
                ProcessSpec(
                    kind: .testFixture,
                    executable: "/usr/bin/printenv",
                    arguments: [key],
                    directory: FileManager.default.temporaryDirectory.path,
                    environment: [key: value],
                    timeout: .seconds(5)))
            try #require(outcome.exitCode == 0)
            try #require(outcome.standardOutputText == value + "\n")
        }
    }
}
