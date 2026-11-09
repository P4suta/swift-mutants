// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import SwiftMutants
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

@Suite("CLI execution", .serialized)
struct CLIIntegrationTests {
    static var binary: URL {
        let scratch =
            ProcessInfo.processInfo.environment["SWIFT_MUTANTS_TEST_SCRATCH_PATH"] ?? ".build"
        let directory =
            scratch.hasPrefix("/")
            ? URL(filePath: scratch) : RepositoryGate.root.appending(path: scratch)
        return directory.appending(path: "debug/swift-mutants")
    }

    @Test("CLI JSON agrees with the public API and strict mode reports survivors")
    func parity() async throws {
        let package = try PackageFixture(tests: PackageFixture.testing)
        defer { try? package.remove() }
        let report = try await MutationTesting.run(packageAt: package.root)
        let outcome = await Runner(recorder: TraceRecorder()).run(
            ProcessSpec(
                kind: .testFixture,
                executable: Self.binary.path,
                arguments: ["run", "--package-path", package.root.path, "--json", "--strict"],
                directory: package.root.path,
                environment: ProcessInfo.processInfo.environment,
                timeout: .seconds(120)
            )
        )
        #expect(outcome.exitCode == 1)
        let decoded = try JSONDecoder().decode(Report.self, from: Data(outcome.standardOutput))
        #expect(decoded.schemaVersion == report.schemaVersion)
        #expect(decoded.score == report.score)
        #expect(decoded.results.map(\.mutation.id) == report.results.map(\.mutation.id))
        #expect(decoded.results.map(\.outcome) == report.results.map(\.outcome.rawValue))
        #expect(!outcome.standardOutputText.contains("Baseline"))
        #expect(outcome.standardErrorText.contains("Baseline 4/4 passed"))
    }

    @Test("legacy configuration fails with a migration message")
    func configuration() async throws {
        let package = try PackageFixture(tests: PackageFixture.testing)
        defer { try? package.remove() }
        try package.write(".swift-mutants.toml", "[mutation]\nprofile = 'balanced'\n")
        try package.write("reports/previous.json", "preserved")
        let result = await Runner(recorder: TraceRecorder()).run(
            ProcessSpec(
                kind: .testFixture,
                executable: Self.binary.path,
                arguments: ["run", "--package-path", package.root.path, "--json"],
                directory: package.root.path,
                environment: ProcessInfo.processInfo.environment,
                timeout: .seconds(10)
            )
        )
        #expect(result.exitCode == 2)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardErrorText.contains("--include"))
        #expect(
            try String(
                contentsOf: package.root.appending(path: "reports/previous.json"),
                encoding: .utf8
            ) == "preserved"
        )
    }

    @Test(
        "signals cancel the task and reap owned descendants",
        arguments: [SIGINT, SIGTERM, SIGHUP]
    )
    func signals(number: Int32) async throws {
        let package = try PackageFixture(tests: PackageFixture.testing)
        defer { try? package.remove() }
        let toolDirectory = package.root.appending(path: "tools")
        try FileManager.default.createDirectory(
            at: toolDirectory,
            withIntermediateDirectories: true
        )
        let marker = package.root.appending(path: "children")
        let script = """
            #!/bin/sh
            if [ "$1" = build ]; then
                /bin/sleep 60 &
                printf '%s %s' "$$" "$!" > '\(marker.path)'
                wait
            else
                exec /usr/bin/swift "$@"
            fi
            """
        let swift = toolDirectory.appending(path: "swift")
        try script.write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = ["run", "--package-path", package.root.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = toolDirectory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try await Self.waitUntil {
            FileManager.default.fileExists(atPath: marker.path) || !process.isRunning
        }
        let pids = try String(contentsOf: marker, encoding: .utf8).split(separator: " ").compactMap
        { Int32($0) }
        kill(process.processIdentifier, number)
        try await Self.waitUntil { !process.isRunning }
        process.waitUntilExit()
        #expect(process.terminationStatus == 128 + number)
        for pid in pids {
            try await Self.waitUntil { kill(pid, 0) == -1 }
            #expect(kill(pid, 0) == -1)
        }
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }
}

private struct Report: Decodable {
    let schemaVersion: Int
    let score: Double?
    let results: [Result]

    struct Result: Decodable {
        let mutation: Identity
        let outcome: String
    }

    struct Identity: Decodable { let id: String }
}
