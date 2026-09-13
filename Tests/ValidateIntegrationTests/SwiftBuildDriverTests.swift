// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsValidate

/// Asking SwiftPM whether a package builds.
///
/// The driver validation actually uses, and the reason is module structure. A package is
/// not a pile of files: each target compiles on its own, against its own dependencies and
/// search paths. Handing every source file in a multi-target package to one
/// `swiftc -typecheck` compiles none of them - the imports resolve to nothing, and the
/// errors are about the arrangement rather than about any mutant. This is the test that
/// says so, on a package with two targets that depend on each other.
@Suite("Building as validation")
struct SwiftBuildDriverTests {

    struct Fixture {
        let root: URL
        let scratch: URL
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    /// Two targets, one importing the other.
    static func fixture(core: String) throws -> Fixture {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-driver-\(identifier)")
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-driver-scratch-\(identifier)")

        try write(
            """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "Two",
                targets: [
                    .target(name: "Core"),
                    .target(name: "App", dependencies: ["Core"]),
                    .testTarget(name: "AppTests", dependencies: ["App"]),
                ]
            )
            """, to: root.appending(path: "Package.swift"))
        try write(core, to: root.appending(path: "Sources/Core/Core.swift"))
        try write(
            """
            import Core
            public func doubled(_ value: Int) -> Int { return twice(value) }
            """, to: root.appending(path: "Sources/App/App.swift"))
        try write(
            """
            import Testing
            @testable import App

            @Suite("App")
            struct AppTests {
                @Test("doubles") func doubles() { #expect(doubled(2) == 4) }
            }
            """, to: root.appending(path: "Tests/AppTests/AppTests.swift"))

        return Fixture(root: root, scratch: scratch)
    }

    static func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    static func environment() -> [String: String] {
        let ambient = ProcessInfo.processInfo.environment
        return ["HOME", "PATH", "DEVELOPER_DIR", "TMPDIR", "SDKROOT"]
            .reduce(into: [:]) { kept, name in kept[name] = ambient[name] }
    }

    static func driver(_ fixture: Fixture) -> SwiftBuildDriver {
        SwiftBuildDriver(
            runner: Runner(recorder: TraceRecorder()),
            root: fixture.root.path,
            scratch: fixture.scratch.path,
            environment: Self.environment()
        )
    }

    /// A `swiftc -typecheck` over both files at once would fail on `import Core`. SwiftPM
    /// plans the build, so it does not.
    @Test("accepts a package whose targets import each other", .tags(.integration))
    func acceptsAMultiTargetPackage() async throws {
        let fixture = try Self.fixture(core: "public func twice(_ value: Int) -> Int { value * 2 }")
        defer { fixture.cleanUp() }

        let output = await Self.driver(fixture).typecheck([])
        #expect(output.exitCode == 0, "\(output.text)")
    }

    /// The reason the driver exists, kept as a test so nobody has to rediscover it.
    ///
    /// The same package, handed to one `swiftc -typecheck` as a list of files, does not
    /// compile: `import Core` resolves to nothing because there is no Core module, only
    /// the file that would have become one. The errors are about the arrangement rather
    /// than about any mutant, and a validator driven this way blames whichever file it
    /// happens to be narrowing.
    @Test("a bare compiler over the same files does not compile them", .tags(.integration))
    func bareCompilerCannotDoThis() async throws {
        let fixture = try Self.fixture(core: "public func twice(_ value: Int) -> Int { value * 2 }")
        defer { fixture.cleanUp() }

        let output = await SwiftcDriver(
            runner: Runner(recorder: TraceRecorder()),
            extraArguments: ["-swift-version", "6"],
            directory: fixture.root.path,
            environment: Self.environment()
        ).typecheck([
            fixture.root.appending(path: "Sources/Core/Core.swift").path,
            fixture.root.appending(path: "Sources/App/App.swift").path,
        ])

        #expect(output.exitCode != 0)
        #expect(output.text.contains("no such module 'Core'"), "\(output.text)")
    }

    /// And when something really is wrong, it says so in a form the parser reads.
    @Test("reports what the compiler said, where it said it", .tags(.integration))
    func reportsDiagnostics() async throws {
        let fixture = try Self.fixture(
            core: "public func twice(_ value: Int) -> Int { return \"not an integer\" }")
        defer { fixture.cleanUp() }

        let output = await Self.driver(fixture).typecheck([])
        #expect(output.exitCode != 0)

        let diagnostics = CompilerDiagnostic.parse(output.text)
        let errors = diagnostics.filter { $0.severity == .error }
        #expect(!errors.isEmpty, "\(output.text)")
        #expect(
            errors.contains { $0.file.hasSuffix("Sources/Core/Core.swift") }, "\(output.text)")
        #expect(errors.allSatisfy { $0.position.line >= 1 && $0.position.column >= 1 })
    }
}
