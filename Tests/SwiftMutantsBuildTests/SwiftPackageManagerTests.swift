// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsBuild

/// Asking a package what it holds.
///
/// Every case here would otherwise need a real package on disk and a real toolchain run.
/// With a scripted `swift` they are a few lines each and cost milliseconds, which is the
/// difference between testing the failure modes and hoping about them.
@Suite("Swift package manager")
struct SwiftPackageManagerTests {

    /// A directory that exists, because a process cannot be started in one that does not
    /// and the failure would be about that rather than about what these tests are asking.
    static let root = FileManager.default.temporaryDirectory

    /// The prefix the decoding tests pretend a package sits at.
    static let describedRoot = URL(filePath: "/tmp/example")

    static func description(_ json: String) throws -> WorkspaceDescription {
        try SwiftPackageManager.decode(Array(json.utf8), root: Self.describedRoot)
    }

    @Test("reads the targets a package describes")
    func readsTargets() throws {
        let description = try Self.description(
            """
            {
              "name": "Example",
              "targets": [
                { "name": "Core", "type": "library", "path": "/tmp/example/Sources/Core",
                  "sources": ["A.swift", "Nested/B.swift"] },
                { "name": "CoreTests", "type": "test", "path": "/tmp/example/Tests/CoreTests",
                  "sources": ["ATests.swift"] }
              ]
            }
            """
        )
        #expect(description.name == "Example")
        #expect(description.targets.map(\.name) == ["Core", "CoreTests"])
        #expect(
            description.targets.first?.sources.map(\.rendered) == [
                "Sources/Core/A.swift", "Sources/Core/Nested/B.swift",
            ]
        )
    }

    /// Only code that ships. Mutating a test would measure whether the tests test
    /// themselves, and a plugin or a macro runs at build time against a different program.
    @Test("mutates only what ships")
    func selectsWhatShips() throws {
        let description = try Self.description(
            """
            {
              "name": "Example",
              "targets": [
                { "name": "Core", "type": "library", "path": "/tmp/example/Sources/Core", "sources": ["A.swift"] },
                { "name": "Tool", "type": "executable", "path": "/tmp/example/Sources/Tool", "sources": ["B.swift"] },
                { "name": "CoreTests", "type": "test", "path": "/tmp/example/Tests/CoreTests", "sources": ["C.swift"] },
                { "name": "Gen", "type": "plugin", "path": "/tmp/example/Plugins/Gen", "sources": ["D.swift"] },
                { "name": "Macros", "type": "macro", "path": "/tmp/example/Sources/Macros", "sources": ["E.swift"] }
              ]
            }
            """
        )
        #expect(description.mutableTargets.map(\.name) == ["Core", "Tool"])
    }

    /// An absolute path must never reach a mutant identity, so it is cut back here rather
    /// than at whichever later place happens to notice.
    @Test("turns the absolute paths a package prints into relative ones")
    func pathsAreMadeRelative() throws {
        let description = try Self.description(
            """
            {"name":"Example","targets":[
              {"name":"Core","type":"library","path":"/tmp/example/Sources/Core","sources":["A.swift"]}]}
            """
        )
        #expect(description.targets.first?.sources.first?.rendered == "Sources/Core/A.swift")
    }

    /// Guessing about a kind would be guessing about whether the code ships.
    @Test("does not mutate a kind of target it has not been taught")
    func unknownKindsAreNotMutated() throws {
        let description = try Self.description(
            """
            {"name":"Example","targets":[
              {"name":"Odd","type":"somethingNew","path":"/tmp/example/Sources/Odd","sources":["A.swift"]}]}
            """
        )
        #expect(description.mutableTargets.isEmpty)
    }

    @Test("holds a package with no targets")
    func emptyPackage() throws {
        #expect(try Self.description(#"{"name":"Empty","targets":[]}"#).targets.isEmpty)
    }

    @Test("refuses something that is not a package description")
    func refusesNonsense() {
        #expect(throws: BuildSystemError.self) { try Self.description("not json at all") }
        #expect(throws: BuildSystemError.self) { try Self.description(#"{"unexpected":true}"#) }
    }

    // MARK: - Through a scripted toolchain

    @Test("asks the toolchain, and reads what it answers")
    func asksTheToolchain() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "package", "describe"],
                standardOutput: """
                    {"name":"Example","targets":[
                      {"name":"Core","type":"library","path":"/tmp/example/Sources/Core",
                       "sources":["A.swift"]}]}
                    """
            )
        ])
        defer { fake.cleanUp() }

        let description = try await SwiftPackageManager(
            root: Self.root,
            runner: Runner(recorder: TraceRecorder()),
            executable: "\(fake.pathEntry)/swift"
        ).describe(environment: fake.environment)
        #expect(description.targets.first?.name == "Core")
    }

    /// A manifest that does not compile is the commonest thing to go wrong in a fresh
    /// checkout, and the toolchain's own words are the only useful thing to say about it.
    @Test("carries the toolchain's own complaint when a manifest will not build")
    func carriesTheToolchainsComplaint() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "package", "describe"],
                exitCode: 1,
                standardError: "error: Package.swift:12:9: cannot find 'targetz' in scope\n"
            )
        ])
        defer { fake.cleanUp() }

        // Written with `#expect(throws:)` rather than do/catch: the latter shape crashes
        // the Swift 6.3.3 compiler in SILGenCleanup inside an async test function.
        let failure = await #expect(throws: BuildSystemError.self) {
            _ = try await SwiftPackageManager(
                root: Self.root,
                runner: Runner(recorder: TraceRecorder()),
                executable: "\(fake.pathEntry)/swift"
            ).describe(environment: fake.environment)
        }
        #expect(failure?.description.contains("cannot find 'targetz'") == true, "\(failure as Any)")
    }

    /// A `swift` that hangs cannot be installed, so this is the only way the deadline around
    /// it gets tested at all.
    ///
    /// And what it says matters as much as that it stops. Reported from a machine whose
    /// Gatekeeper and Spotlight daemons were saturated: a freshly built manifest executable
    /// sat waiting to be *allowed to start*, having used a hundredth of a second of
    /// processor time and never reached `main`. This deadline fired, and the message said
    /// `swift package describe` exited 143. It said nothing. - which reads as a fact about
    /// the package. An hour went into reading a manifest that was never wrong.
    @Test("says a toolchain that stopped answering did not answer")
    func saysWhenTheToolchainStopsAnswering() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "package", "describe"],
                delayMilliseconds: 30_000
            )
        ])
        defer { fake.cleanUp() }

        let thrown = await #expect(throws: BuildSystemError.self) {
            _ = try await SwiftPackageManager(
                root: Self.root,
                runner: Runner(recorder: TraceRecorder()),
                executable: "\(fake.pathEntry)/swift"
            ).describe(environment: fake.environment, timeout: .milliseconds(200))
        }
        let said = try #require(thrown?.description)
        #expect(said.contains("did not answer"), "\(said)")
        #expect(said.contains("200ms"), "it should say how long it waited: \(said)")
        // Never the exit status. A deadline's signal is this tool's own doing, and a number
        // a reader would look up is a number pointing them at their own package.
        #expect(!said.contains("143"), "\(said)")
        #expect(!said.contains("It said nothing"), "\(said)")
    }

    /// The first invariant of the family, at the one place it was being broken.
    ///
    /// `swift package describe` is not a read. SwiftPM lays a scratch directory down beside
    /// the manifest it compiled - `.build/CACHEDIR.TAG` and a build-system marker - so the
    /// command this tool reaches for *because* it changes nothing was writing into the
    /// repository somebody was working in. `list` does it too, on a tree it never copies.
    ///
    /// Asserted on the argv rather than on a directory afterwards, because the promise is
    /// about what the process was told: a test that checked the tree could pass on a
    /// machine whose SwiftPM happened to write nothing that day.
    @Test("tells the toolchain to put its scratch somewhere that is not the package")
    func keepsItsScratchOutOfThePackage() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "package", "describe"],
                standardOutput: #"{"name":"Example","targets":[]}"#
            )
        ])
        defer { fake.cleanUp() }

        let recorder = TraceRecorder(retaining: 8)
        _ = try await SwiftPackageManager(
            root: Self.root,
            runner: Runner(recorder: recorder),
            executable: "\(fake.pathEntry)/swift"
        ).describe(environment: fake.environment)

        let asked = recorder.retainedEvents().compactMap { event -> TraceEvent.Execution? in
            if case .exec(let execution) = event.kind { return execution }
            return nil
        }.first
        let arguments = try #require(asked?.arguments)
        let index = try #require(arguments.firstIndex(of: "--scratch-path"))
        // Before the subcommand: SwiftPM refuses it after `describe` with exit 64.
        #expect(arguments.firstIndex(of: "describe").map { index < $0 } == true)
        let scratch = try #require(
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil)
        #expect(!scratch.hasPrefix(Self.root.standardizedFileURL.path), "\(scratch)")
    }

    /// Every command a run makes is in its account, including the ones that failed.
    @Test("writes down what it asked")
    func recordsWhatItAsked() async throws {
        let fake = try FakeToolchain([
            FakeToolchainRule(
                whenArgumentsContain: ["swift", "package", "describe"],
                standardOutput: #"{"name":"Example","targets":[]}"#
            )
        ])
        defer { fake.cleanUp() }

        let recorder = TraceRecorder(retaining: 8)
        _ = try await SwiftPackageManager(
            root: Self.root,
            runner: Runner(recorder: recorder),
            executable: "\(fake.pathEntry)/swift"
        ).describe(environment: fake.environment)

        let recorded = recorder.retainedEvents().compactMap { event -> TraceEvent.Execution? in
            if case .exec(let execution) = event.kind { return execution }
            return nil
        }
        #expect(recorded.count == 1)
        #expect(recorded.first?.label == "describe")
        #expect(recorded.first?.arguments.contains("describe") == true)
    }
}
