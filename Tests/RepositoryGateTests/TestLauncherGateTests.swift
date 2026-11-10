// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

@Suite("Test launcher compatibility")
struct TestLauncherGateTests {
    @Test(
        "the toolchain selects the concurrency policy",
        arguments: [
            ("Apple Swift version 6.3.3 (swiftlang-6.3.3)", "--no-parallel"),
            ("Apple Swift version 6.4.2 (swiftlang-6.4.2)", "--parallel"),
            ("Swift version 7.0.0 (swift-7.0-RELEASE)", "--parallel"),
            ("unrecognized version banner", "--no-parallel"),
        ]
    )
    func concurrency(banner: String, expected: String) async throws {
        let result = try await launch(banner: banner, arguments: ["--filter", "selected test"])
        #expect(result.exitCode == 0)
        #expect(
            result.standardOutputText
                == "arg=test\narg=\(expected)\narg=--filter\narg=selected test\nscratch=\n")
    }

    @Test(
        "explicit concurrency and scratch paths pass through unchanged",
        arguments: [
            ["--parallel", "--scratch-path", "/tmp/fixture with spaces"],
            ["--no-parallel", "--scratch-path=/tmp/fixture with spaces"],
            ["--num-workers", "2", "--scratch-path", "/tmp/fixture with spaces"],
            ["--num-workers=2", "--scratch-path=/tmp/fixture with spaces"],
        ]
    )
    func explicitOptions(arguments: [String]) async throws {
        let result = try await launch(banner: "", arguments: arguments)
        #expect(result.exitCode == 0)
        let expected =
            (["test"] + arguments).map { "arg=\($0)\n" }.joined()
            + "scratch=/tmp/fixture with spaces\n"
        #expect(result.standardOutputText == expected)
    }

    private func launch(banner: String, arguments: [String]) async throws -> ProcessOutcome {
        let fixture = """
            #!/bin/bash
            if [[ $1 == --version ]]; then
                [[ -n $SWIFT_MUTANTS_FIXTURE_BANNER ]] || exit 42
                printf '%s\\n' "$SWIFT_MUTANTS_FIXTURE_BANNER"
            else
                printf 'arg=%s\\n' "$@"
                printf 'scratch=%s\\n' "${SWIFT_MUTANTS_TEST_SCRATCH_PATH-}"
            fi
            """
        let tools = FileManager.default.temporaryDirectory.appending(
            path: "launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        let executable = tools.appending(path: "swift")
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(tools.path):\(environment["PATH", default: "/usr/bin:/bin"])"
        environment["SWIFT_MUTANTS_FIXTURE_BANNER"] = banner
        environment.removeValue(forKey: "SWIFT_MUTANTS_TEST_SCRATCH_PATH")
        return await Runner(recorder: TraceRecorder()).run(
            ProcessSpec(
                kind: .testFixture,
                executable: "/bin/bash",
                arguments: ["scripts/swift-test.sh"] + arguments,
                directory: RepositoryGate.root.path,
                environment: environment,
                timeout: .seconds(10)
            )
        )
    }
}
