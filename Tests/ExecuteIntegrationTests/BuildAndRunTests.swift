// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

/// Building a real package's tests once, then running them again and again.
///
/// The economy the whole tool rests on, put to a real toolchain. Everything up to here is
/// a statement about arguments and scripted output; this is the part that finds out whether
/// a built test bundle can actually be started twice, with a different answer each time.
///
/// It is also where the platform is allowed to disagree. On macOS the built product is a
/// bundle that cannot be executed and has to be loaded by SwiftPM's helper; elsewhere it is
/// an executable. The adapter asks the filesystem which it got, and this asks whether the
/// answer works.
@Suite("Building and running a real package")
struct BuildAndRunTests {

    /// A package on disk with one function and one test, and the way to take it away.
    struct Fixture {
        let root: URL
        let scratch: URL
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    /// Writes a package whose one test reads an environment variable.
    ///
    /// Not a mutant, but the same mechanism: the point is that the same built bundle gives
    /// a different answer on a later run because the environment changed, which is exactly
    /// what activating a mutant does.
    static func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-build-\(UUID().uuidString)")
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-scratch-\(UUID().uuidString)")

        try write(
            """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "Subject",
                targets: [
                    .target(name: "Subject"),
                    .testTarget(name: "SubjectTests", dependencies: ["Subject"]),
                ]
            )
            """, to: root.appending(path: "Package.swift"))

        try write(
            """
            #if canImport(Darwin)
            import func Darwin.getenv
            #else
            import func Glibc.getenv
            #endif

            public func answer() -> Int {
                guard let raw = getenv("SWIFT_MUTANTS_ACTIVE"),
                      let value = Int(String(cString: raw))
                else { return 1 }
                return value
            }
            """, to: root.appending(path: "Sources/Subject/Subject.swift"))

        try write(
            """
            import Testing
            @testable import Subject

            @Suite("Answers")
            struct SubjectTests {
                @Test("is one") func isOne() { #expect(answer() == 1) }
                @Test("is still one") func stillOne() { #expect(answer() == 1) }
            }
            """, to: root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        return Fixture(root: root, scratch: scratch)
    }

    static func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    /// One build, two runs, two different answers.
    @Test("builds once and runs a package's tests twice", .tags(.integration))
    func buildOnceRunTwice() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let runner = Runner(recorder: TraceRecorder())

        let plan = try await SwiftPackageManager(
            root: fixture.root, runner: runner, executable: "/usr/bin/swift"
        ).buildForTesting(scratch: fixture.scratch.path, environment: Self.environment())

        let trial = Trial(
            plan: plan, runner: runner, scratch: fixture.scratch, timeout: .seconds(300))

        // Nothing activated: the package's own tests pass, as they do for anybody.
        let baseline = await trial.run(activating: nil)
        #expect(baseline.outcome == .survived, "\(baseline)")
        #expect(baseline.testsStarted >= 2)

        // Something activated: the same bundle, a different program, a failing test.
        let activated = await trial.run(activating: 7)
        #expect(activated.outcome == .killed, "\(activated)")
        #expect(activated.killedBy.count == 1, "the suite should have been stopped at the first")
        #expect(activated.termination == .stopped)
    }

    /// A package with no tests has nothing for a mutant to be caught by, and the tool says
    /// so rather than reporting a run in which everything survived.
    @Test("says a package with no tests has nothing to catch a mutant", .tags(.integration))
    func noTests() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.root.appending(path: "Tests"))
        try Self.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "Subject", targets: [.target(name: "Subject")])
            """, to: fixture.root.appending(path: "Package.swift"))

        let failure = await #expect(throws: BuildSystemError.self) {
            try await SwiftPackageManager(
                root: fixture.root,
                runner: Runner(recorder: TraceRecorder()),
                executable: "/usr/bin/swift"
            ).buildForTesting(scratch: fixture.scratch.path, environment: Self.environment())
        }
        #expect(failure?.description.contains("no test bundle") == true)
    }

    /// A package that does not compile is reported in the compiler's words, not as a
    /// missing bundle three steps later.
    @Test("says what the compiler said when a package will not build", .tags(.integration))
    func brokenPackage() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        try Self.write(
            "public func answer() -> Int { return \"not an integer\" }",
            to: fixture.root.appending(path: "Sources/Subject/Subject.swift"))

        let failure = await #expect(throws: BuildSystemError.self) {
            try await SwiftPackageManager(
                root: fixture.root,
                runner: Runner(recorder: TraceRecorder()),
                executable: "/usr/bin/swift"
            ).buildForTesting(scratch: fixture.scratch.path, environment: Self.environment())
        }
        #expect(failure?.description.contains("swift build --build-tests") == true)
    }

    /// SwiftPM needs a home, a PATH and a developer directory. Passing the whole ambient
    /// environment would make the test depend on whatever ran it.
    static func environment() -> [String: String] {
        let ambient = ProcessInfo.processInfo.environment
        return ["HOME", "PATH", "DEVELOPER_DIR", "TMPDIR", "SDKROOT"]
            .reduce(into: [:]) { kept, name in kept[name] = ambient[name] }
    }
}

extension Tag {
    /// Needs a real Swift toolchain.
    @Tag static var integration: Self
}
