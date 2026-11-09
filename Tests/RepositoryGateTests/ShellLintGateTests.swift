// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

@Suite("Shell lint failures")
struct ShellLintGateTests {
    @Test("source discovery failure fails the maintained shell lint task")
    func discoveryFailure() async throws {
        let definition = await run(["mise", "tasks", "info", "lint:shell", "--json"])
        try #require(definition.exitCode == 0, "\(definition.standardErrorText)")
        let task = try JSONDecoder().decode(
            TaskDefinition.self,
            from: Data(definition.standardOutput)
        )
        let shell =
            task.shell?.split(whereSeparator: \.isWhitespace).map(String.init)
            ?? ["sh", "-c"]
        let source = try #require(task.run.first)
        let script = "rg() { printf 'fixture discovery failed\\n' >&2; return 42; };\n" + source
        let result = await run(shell + [script])
        #expect(!result.timedOut)
        #expect(result.startFailure == nil)
        #expect(result.standardErrorText.contains("fixture discovery failed"))
        #expect(result.exitCode != 0)
    }

    private func run(_ arguments: [String]) async -> ProcessOutcome {
        await Runner(recorder: TraceRecorder()).run(
            ProcessSpec(
                kind: .testFixture,
                executable: "/usr/bin/env",
                arguments: arguments,
                directory: RepositoryGate.root.path,
                environment: ProcessInfo.processInfo.environment,
                timeout: .seconds(10)
            )
        )
    }

    private struct TaskDefinition: Decodable {
        let shell: String?
        let run: [String]
    }
}
