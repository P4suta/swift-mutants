// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

/// A toolchain that misbehaves on purpose, in the unit tier.
///
/// Every case here is one that would otherwise be untestable or unaffordable. A `swift
/// build` that hangs cannot be installed. A toolchain that prints garbage for `--version`
/// exists nowhere. A red baseline needs a project that fails, kept failing, forever. With a
/// scripted toolchain each is a few lines and a few milliseconds, which is the difference
/// between having these tests and not.
@Suite("Fake toolchain")
struct FakeToolchainTests {

    static func spec(
        _ tool: String,
        _ arguments: [String],
        fake: FakeToolchain,
        timeout: Duration? = nil
    ) -> ProcessSpec {
        ProcessSpec(
            kind: .testFixture,
            executable: "\(fake.pathEntry)/\(tool)",
            arguments: arguments,
            directory: FileManager.default.temporaryDirectory.path,
            environment: fake.environment,
            timeout: timeout
        )
    }

    @Test("answers a scripted command")
    func answersAScriptedCommand() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "--version"],
                standardOutput: "Apple Swift version 6.3.3\n"
            )
        ])
        defer { fake.cleanUp() }

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("swift", ["--version"], fake: fake)
        )
        #expect(outcome.exitCode == 0)
        #expect(String(decoding: outcome.standardOutput, as: UTF8.self).contains("6.3.3"))
    }

    /// The failure a version probe has to survive, and which no real toolchain will
    /// reproduce on demand.
    @Test("can be made to answer with something that is not a version")
    func answersWithGarbage() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "--version"],
                standardOutput: "\u{0}\u{1}not a version at all\n"
            )
        ])
        defer { fake.cleanUp() }

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("swift", ["--version"], fake: fake)
        )
        #expect(outcome.exitCode == 0)
        #expect(!String(decoding: outcome.standardOutput, as: UTF8.self).contains("Swift version"))
    }

    /// The one that cannot be installed. A toolchain that never returns is scripted as a
    /// delay longer than any deadline a test would set.
    @Test("can be made to hang, so the supervisor's deadline can be tested without one")
    func canBeMadeToHang() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "build"],
                delayMilliseconds: 30_000
            )
        ])
        defer { fake.cleanUp() }

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("swift", ["build"], fake: fake, timeout: .milliseconds(200))
        )
        #expect(outcome.timedOut)
    }

    @Test("can be made to leave a red baseline behind")
    func canBeMadeToFail() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "test"],
                exitCode: 1,
                standardError: "error: 3 tests failed\n"
            )
        ])
        defer { fake.cleanUp() }

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("swift", ["test"], fake: fake)
        )
        #expect(outcome.exitCode == 1)
        #expect(String(decoding: outcome.standardError, as: UTF8.self).contains("3 tests failed"))
    }

    /// A build that produces nothing is indistinguishable from a build that failed, so a
    /// scripted build has to be able to leave its products behind.
    @Test("can be made to produce the artefacts a real build would")
    func canBeMadeToProduceArtefacts() async throws {
        let product = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-fake-product-\(UUID().uuidString)")
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "build"],
                writes: [product.path: "a built thing"]
            )
        ])
        defer {
            fake.cleanUp()
            try? FileManager.default.removeItem(at: product)
        }

        _ = await Runner(recorder: TraceRecorder()).run(Self.spec("swift", ["build"], fake: fake))
        #expect(try String(contentsOf: product, encoding: .utf8) == "a built thing")
    }

    /// The invariant that makes the whole thing trustworthy: a test cannot accidentally
    /// exercise a command nobody wrote a rule for and take the answer as meaningful.
    @Test("refuses a command nobody scripted, distinctly")
    func refusesAnUnscriptedCommand() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(whenArgumentsContain: ["swift", "--version"])
        ])
        defer { fake.cleanUp() }

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("swift", ["package", "describe"], fake: fake)
        )
        #expect(outcome.exitCode == 97)
        #expect(String(decoding: outcome.standardError, as: UTF8.self).contains("no rule matched"))
    }

    /// The assertion the unit tier could not otherwise make: what a child process really
    /// received, rather than what a struct said it would be given.
    @Test("records the argument vector and the variables a child really received")
    func recordsWhatTheChildReceived() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(whenArgumentsContain: ["swift", "build"])
        ])
        defer { fake.cleanUp() }

        var environment = fake.environment
        environment["SWIFT_MUTANTS_ACTIVE"] = "4fcc205c"
        environment["A_SECRET"] = "hunter2"

        _ = await Runner(recorder: TraceRecorder()).run(
            ProcessSpec(
                kind: .testFixture,
                executable: "\(fake.pathEntry)/swift",
                arguments: ["build", "--build-tests"],
                directory: FileManager.default.temporaryDirectory.path,
                environment: environment,
                timeout: nil
            )
        )

        let call = try #require(try fake.calls().first)
        #expect(call.arguments.dropFirst() == ["build", "--build-tests"])
        #expect(call.environment["SWIFT_MUTANTS_ACTIVE"] == "4fcc205c")
        // A call log is uploaded as a CI artefact, so a variable that is neither a path nor
        // a flag list is recorded by name alone.
        #expect(call.environment["A_SECRET"] == nil)
        #expect(call.environmentNames.contains("A_SECRET"))
    }

    @Test("wears whichever name it was invoked under")
    func matchesOnTheInvokedName() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["xcodebuild", "-list"], standardOutput: "schemes\n"),
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "-list"], standardOutput: "not schemes\n"),
        ])
        defer { fake.cleanUp() }

        let outcome = await Runner(recorder: TraceRecorder()).run(
            Self.spec("xcodebuild", ["-list"], fake: fake)
        )
        #expect(String(decoding: outcome.standardOutput, as: UTF8.self) == "schemes\n")
    }
}
