// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsRunner
import SwiftMutantsTrace
import SwiftMutantsValidate
import Testing

/// Asking Xcode whether a tree compiles.
///
/// The Xcode path's answer to the same question the SwiftPM path asks, and it has to come
/// back in the same shape: `path:line:col: error: message`, which is what attribution reads.
/// A translation layer between the two would be a layer to keep in step with Xcode, so this
/// is the test that says there does not need to be one.
@Suite("Asking Xcode whether a tree compiles")
struct XcodeBuildDriverTests {

    struct Fixture {
        let root: URL
        let derivedData: URL
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: derivedData)
        }
    }

    /// A package whose two source files can each be broken on their own.
    ///
    /// Two, because the thing worth proving is that one round surfaces the errors in both:
    /// each round of validation is a build, and a round that reports one file's worth
    /// costs what a round that reports all of them costs.
    static func fixture(first: String, second: String) throws -> Fixture {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-xcvalidate-\(identifier)")
        let fixture = Fixture(
            root: root,
            derivedData: FileManager.default.temporaryDirectory
                .appending(path: "swift-mutants-xcvalidate-dd-\(identifier)")
        )
        try Self.write(
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
        try Self.write(first, to: root.appending(path: "Sources/Subject/First.swift"))
        try Self.write(second, to: root.appending(path: "Sources/Subject/Second.swift"))
        try Self.write(
            """
            import Testing

            @testable import Subject

            @Test func t() { #expect(Bool(true)) }
            """, to: root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))
        return fixture
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

    static func driver(_ fixture: Fixture) -> XcodeBuildDriver {
        XcodeBuildDriver(
            runner: Runner(recorder: TraceRecorder()),
            root: fixture.root.path,
            scheme: "Subject-Package",
            destination: "platform=macOS",
            derivedData: fixture.derivedData.path,
            environment: Self.environment()
        )
    }

    /// Two files that compile, and that do not collide: written to both halves of the
    /// fixture, one declaration would be a redeclaration and the build would fail for a
    /// reason no test meant.
    static let good = "public func good(_ a: Int, _ b: Int) -> Bool { a >= b }"
    static let alsoGood = "public func also(_ a: Int) -> Int { a + 1 }"

    @Test("says a tree that compiles compiles", .tags(.toolchain))
    func acceptsAGoodTree() async throws {
        let fixture = try Self.fixture(
            first: Self.good, second: Self.alsoGood)
        defer { fixture.cleanUp() }
        let output = await Self.driver(fixture).typecheck([])
        #expect(output.exitCode == 0)
    }

    /// The shape attribution reads, from Xcode's own mouth.
    @Test("says where an error is in the words attribution reads", .tags(.toolchain))
    func reportsInTheUsualShape() async throws {
        let fixture = try Self.fixture(
            first: "public func bad(_ a: String, _ b: String) -> Bool { a - b }",
            second: Self.alsoGood
        )
        defer { fixture.cleanUp() }
        let output = await Self.driver(fixture).typecheck([])
        #expect(output.exitCode != 0)

        let diagnostics = CompilerDiagnostic.parse(output.text)
        let mine = diagnostics.filter { $0.file.hasSuffix("First.swift") }
        #expect(mine.count >= 1)
        #expect(mine.first?.severity == .error)
        #expect(mine.first?.position.line == 1)
        #expect(mine.first?.message.contains("binary operator") == true)
    }

    /// Every error in a file that failed, which is what makes a round worth anything: a
    /// round that reported one of a file's forty rejections would need forty rounds, and
    /// each round is a build.
    ///
    /// Only within a file. Whether a *second* file's errors come back is a race - measured
    /// three times each way with the same two broken files, and the answer differed between
    /// runs - so asserting it would be asserting the scheduler. Validation converges either
    /// way by asking again without what was rejected; the cost is written down in the
    /// driver and in ADR 0006 rather than pinned here.
    @Test("reports every error in a file that failed", .tags(.toolchain))
    func reportsEveryErrorInAFile() async throws {
        let fixture = try Self.fixture(
            first: """
                public func bad(_ a: String, _ b: String) -> Bool { a - b }
                public func alsoBad(_ a: [Int], _ b: [Int]) -> [Int] { a / b }
                """,
            second: Self.alsoGood
        )
        defer { fixture.cleanUp() }
        let output = await Self.driver(fixture).typecheck([])

        let lines = Set(
            CompilerDiagnostic.parse(output.text)
                .filter { $0.severity == .error && $0.file.hasSuffix("First.swift") }
                .map(\.position.line)
        )
        #expect(lines == [1, 2])
    }

    /// And at least one file's worth comes back whichever file the compile got to first.
    @Test("says something about a tree with two broken files", .tags(.toolchain))
    func reportsSomethingFromTwoBrokenFiles() async throws {
        let fixture = try Self.fixture(
            first: "public func bad(_ a: String, _ b: String) -> Bool { a - b }",
            second: "public func worse(_ a: [Int], _ b: [Int]) -> [Int] { a / b }"
        )
        defer { fixture.cleanUp() }
        let output = await Self.driver(fixture).typecheck([])

        let files = Set(
            CompilerDiagnostic.parse(output.text)
                .filter { $0.severity == .error }
                .map { URL(filePath: $0.file).lastPathComponent }
        )
        #expect(!files.isEmpty)
        #expect(files.isSubset(of: ["First.swift", "Second.swift"]))
    }

    /// The test target too, which is why this builds *for testing* rather than building.
    ///
    /// This tool mutates the code a package's tests are made of as readily as the code they
    /// test - measuring itself, it mutates its own test support - and a validation that
    /// compiled only the library would accept a mutant the test target refuses. The build
    /// would then fail later, with nothing left to attribute it to.
    @Test("compiles the tests as well as what they test", .tags(.toolchain))
    func compilesTheTests() async throws {
        let fixture = try Self.fixture(first: Self.good, second: Self.alsoGood)
        defer { fixture.cleanUp() }
        try Self.write(
            """
            import Testing

            @testable import Subject

            // Outside a macro on purpose: an error inside `#expect` is reported against
            // the expansion buffer rather than against this file, which is the same
            // reason mutants are never planted inside one.
            @Test func t() {
                let wrong: Bool = good("a", "b")
                #expect(wrong)
            }
            """,
            to: fixture.root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        let output = await Self.driver(fixture).typecheck([])
        #expect(output.exitCode != 0)
        let mine = CompilerDiagnostic.parse(output.text)
            .filter { $0.severity == .error && $0.file.hasSuffix("SubjectTests.swift") }
        #expect(!mine.isEmpty)
    }

    /// A scheme that is not there is a fact about the project, and it comes back as a
    /// refusal with xcodebuild's own words rather than as an empty success.
    @Test("says so when the scheme is not there", .tags(.toolchain))
    func noSuchScheme() async throws {
        let fixture = try Self.fixture(first: Self.good, second: Self.alsoGood)
        defer { fixture.cleanUp() }
        let driver = XcodeBuildDriver(
            runner: Runner(recorder: TraceRecorder()),
            root: fixture.root.path,
            scheme: "NoSuchScheme",
            destination: "platform=macOS",
            derivedData: fixture.derivedData.path,
            environment: Self.environment()
        )
        let output = await driver.typecheck([])
        #expect(output.exitCode != 0)
        #expect(!output.text.isEmpty)
    }

    /// Nothing is passed that would replace what the project set for itself.
    ///
    /// `OTHER_SWIFT_FLAGS` on the command line does not add to a target's flags, it
    /// replaces them - so a driver that reached for it to pass one compiler option would
    /// silently change how somebody's package is compiled, and the mutants would be
    /// measured against a program they do not ship.
    @Test("changes nothing about how the project compiles itself")
    func changesNothingAboutTheBuild() throws {
        let fixture = try Self.fixture(first: Self.good, second: Self.alsoGood)
        defer { fixture.cleanUp() }
        let arguments = Self.driver(fixture).arguments
        #expect(!arguments.contains { $0.contains("OTHER_SWIFT_FLAGS") })
        #expect(!arguments.contains { $0.contains("SWIFT_TREAT_WARNINGS") })
        // Only the four that say what to build and where to put it.
        #expect(arguments.count == 7)
    }
}

extension Tag {
    /// Needs Xcode, not only a Swift toolchain.
    @Tag static var toolchain: Self
}
