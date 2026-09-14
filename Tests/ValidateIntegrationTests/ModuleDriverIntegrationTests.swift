// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsCore
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsValidate

/// One pass over a package's breadth, instead of one build per module layer.
///
/// This is the claim, tested against a real toolchain on a real package: `swift build`
/// cannot report an error in a module whose dependency failed to build, so two broken
/// modules in two layers take two builds to find. Asked per module against the modules a
/// pristine build already produced, both answer in one pass.
///
/// The saving is the depth of somebody's package. Dogfooding this one took nineteen rounds,
/// each of them a build of everything.
@Suite("Asking each module, for real")
struct ModuleDriverIntegrationTests {

    static func fixture(core: String, app: String) throws -> SwiftBuildDriverTests.Fixture {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-modules-\(identifier)")
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-modules-scratch-\(identifier)")

        try SwiftBuildDriverTests.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "Two",
                targets: [
                    .target(name: "Core"),
                    .target(name: "App", dependencies: ["Core"]),
                ]
            )
            """, to: root.appending(path: "Package.swift"))
        try SwiftBuildDriverTests.write(core, to: root.appending(path: "Sources/Core/Core.swift"))
        try SwiftBuildDriverTests.write(app, to: root.appending(path: "Sources/App/App.swift"))
        return SwiftBuildDriverTests.Fixture(root: root, scratch: scratch)
    }

    static let workingCore = "public func twice(_ value: Int) -> Int { value * 2 }"
    static let workingApp = """
        import Core
        public func doubled(_ value: Int) -> Int { twice(value) }
        """

    /// Builds the package as the user wrote it, and reads the plan SwiftPM made.
    static func prime(_ fixture: SwiftBuildDriverTests.Fixture) async throws -> BuildManifest {
        let output = await SwiftBuildDriverTests.driver(fixture).typecheck([])
        #expect(output.exitCode == 0, "the fixture must build before anything is broken")
        let text = try String(
            contentsOf: fixture.scratch.appending(path: "debug.yaml"), encoding: .utf8)
        return try #require(BuildManifest(parsing: text), "SwiftPM's plan could not be read")
    }

    static func driver(
        _ fixture: SwiftBuildDriverTests.Fixture, _ manifest: BuildManifest
    ) -> ModuleTypecheckDriver {
        ModuleTypecheckDriver(
            runner: Runner(recorder: TraceRecorder()),
            manifest: manifest,
            root: fixture.root.path,
            environment: SwiftBuildDriverTests.environment(),
            fallback: SwiftBuildDriverTests.driver(fixture)
        )
    }

    static func sources(_ fixture: SwiftBuildDriverTests.Fixture) -> [String] {
        [
            fixture.root.appending(path: "Sources/Core/Core.swift").path,
            fixture.root.appending(path: "Sources/App/App.swift").path,
        ]
    }

    /// The plan SwiftPM writes really does name every module and its files.
    @Test("reads the plan SwiftPM wrote", .tags(.integration))
    func readsTheRealPlan() async throws {
        let fixture = try Self.fixture(core: Self.workingCore, app: Self.workingApp)
        defer { fixture.cleanUp() }
        let manifest = try await Self.prime(fixture)

        #expect(manifest.modules.map(\.name).sorted().contains(["App", "Core"]))
        let core = try #require(manifest.modules.first { $0.name == "Core" })
        #expect(core.sources.contains { $0.hasSuffix("Sources/Core/Core.swift") })
    }

    @Test("accepts a package that compiles", .tags(.integration))
    func acceptsWhatCompiles() async throws {
        let fixture = try Self.fixture(core: Self.workingCore, app: Self.workingApp)
        defer { fixture.cleanUp() }
        let manifest = try await Self.prime(fixture)

        let output = await Self.driver(fixture, manifest).typecheck(Self.sources(fixture))
        #expect(output.exitCode == 0, "\(output.text)")
    }

    /// The whole point. Both modules are broken, and the lower one's failure does not hide
    /// the upper one's error, because nothing is reading the lower one's source.
    @Test("reports both layers' errors in one pass", .tags(.integration))
    func reportsBothLayersAtOnce() async throws {
        let fixture = try Self.fixture(
            core: Self.workingCore, app: Self.workingApp)
        defer { fixture.cleanUp() }
        let manifest = try await Self.prime(fixture)

        // Break both, after the plan and the modules exist.
        try SwiftBuildDriverTests.write(
            Self.workingCore + "\npublic let broken: Int = \"in Core\"\n",
            to: fixture.root.appending(path: "Sources/Core/Core.swift"))
        try SwiftBuildDriverTests.write(
            Self.workingApp + "\npublic let broken: Int = \"in App\"\n",
            to: fixture.root.appending(path: "Sources/App/App.swift"))

        let output = await Self.driver(fixture, manifest).typecheck(Self.sources(fixture))

        #expect(output.exitCode != 0)
        #expect(output.text.contains("Core.swift"), "\(output.text)")
        #expect(output.text.contains("App.swift"), "\(output.text)")
    }

    /// And the comparison that makes the claim mean something: the same two files, built
    /// the way validation used to build them, surface one layer and stay silent about the
    /// other. That silence is the nineteen rounds.
    @Test("a build of the package surfaces only the lower layer", .tags(.integration))
    func aBuildSurfacesOneLayer() async throws {
        let fixture = try Self.fixture(core: Self.workingCore, app: Self.workingApp)
        defer { fixture.cleanUp() }
        _ = try await Self.prime(fixture)

        try SwiftBuildDriverTests.write(
            Self.workingCore + "\npublic let broken: Int = \"in Core\"\n",
            to: fixture.root.appending(path: "Sources/Core/Core.swift"))
        try SwiftBuildDriverTests.write(
            Self.workingApp + "\npublic let broken: Int = \"in App\"\n",
            to: fixture.root.appending(path: "Sources/App/App.swift"))

        let output = await SwiftBuildDriverTests.driver(fixture).typecheck([])

        #expect(output.exitCode != 0)
        #expect(output.text.contains("Core.swift"), "\(output.text)")
        #expect(!output.text.contains("App.swift: error"), "\(output.text)")
    }

    /// The error this approach nearly shipped without.
    ///
    /// A whole class of Swift error is found after type checking, while the compiler lowers
    /// the program. `missing return in instance method expected to return` is one, and a
    /// `return-replacement` mutant produces exactly that shape. Asked with `-typecheck` the
    /// compiler exits zero and says nothing; the build that follows validation then fails,
    /// after validation has already said the tree was fine - which is the worst place for a
    /// tool to be wrong, because the run dies rather than answering.
    @Test("finds an error the type checker alone does not", .tags(.integration))
    func findsWhatTypeCheckingMisses() async throws {
        let fixture = try Self.fixture(core: Self.workingCore, app: Self.workingApp)
        defer { fixture.cleanUp() }
        let manifest = try await Self.prime(fixture)

        // A function whose only `return` is behind a condition: well-typed, and not a
        // program.
        try SwiftBuildDriverTests.write(
            """
            public func twice(_ value: Int) -> Int { value * 2 }
            public func thrice(_ value: Int) -> Int {
                if value > 0 { return value * 3 }
            }
            """, to: fixture.root.appending(path: "Sources/Core/Core.swift"))

        let output = await Self.driver(fixture, manifest).typecheck(Self.sources(fixture))

        #expect(output.exitCode != 0)
        #expect(output.text.contains("missing return"), "\(output.text)")
    }

    /// The premise, kept as a test so nobody quietly puts `-typecheck` back: the type
    /// checker really does accept it.
    @Test("and the type checker really does accept it", .tags(.integration))
    func typeCheckingReallyAcceptsIt() async throws {
        let fixture = try Self.fixture(core: Self.workingCore, app: Self.workingApp)
        defer { fixture.cleanUp() }
        let manifest = try await Self.prime(fixture)

        try SwiftBuildDriverTests.write(
            """
            public func twice(_ value: Int) -> Int { value * 2 }
            public func thrice(_ value: Int) -> Int {
                if value > 0 { return value * 3 }
            }
            """, to: fixture.root.appending(path: "Sources/Core/Core.swift"))

        let core = try #require(manifest.modules.first { $0.name == "Core" })
        let asked = core.diagnosingArguments(
            cachingModulesIn: fixture.scratch.appending(path: "ValidationModuleCache").path)
        let typechecking = asked.map { $0 == "-emit-sil" ? "-typecheck" : $0 }
            .filter { $0 != "-wmo" && $0 != "/dev/null" && $0 != "-o" }

        let process = Process()
        process.executableURL = URL(filePath: typechecking[0])
        process.arguments = Array(typechecking.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "the type checker was supposed to miss it")
    }

    /// Writes nothing. Each round of validation is asked against the modules the pristine
    /// build produced, and a round that rebuilt them would be answering later rounds about
    /// a tree that already has mutants in it.
    @Test("leaves the built modules as it found them", .tags(.integration))
    func writesNothing() async throws {
        let fixture = try Self.fixture(core: Self.workingCore, app: Self.workingApp)
        defer { fixture.cleanUp() }
        let manifest = try await Self.prime(fixture)

        let modules = fixture.scratch.appending(path: "arm64-apple-macosx/debug/Modules")
        let before = try FileManager.default.contentsOfDirectory(atPath: modules.path).sorted()
        let stamps = try before.map {
            try FileManager.default.attributesOfItem(
                atPath: modules.appending(path: $0).path)[.modificationDate] as? Date
        }

        _ = await Self.driver(fixture, manifest).typecheck(Self.sources(fixture))

        let after = try FileManager.default.contentsOfDirectory(atPath: modules.path).sorted()
        #expect(after == before)
        #expect(
            try stamps
                == after.map {
                    try FileManager.default.attributesOfItem(
                        atPath: modules.appending(path: $0).path)[.modificationDate] as? Date
                })
    }
}
