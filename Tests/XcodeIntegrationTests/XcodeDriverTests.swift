// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsRunner
import SwiftMutantsTrace
import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsXcode
import Testing

/// Driving the real `xcodebuild`, which is the only thing that proves any of this.
///
/// Everything else in this module is a function of what xcodebuild printed, and every one
/// of those can be tested against text. This is the part that cannot: whether
/// `build-for-testing` writes what this expects where this expects it, whether a document
/// with a variable added still runs, and whether a mutant woken through that document
/// actually behaves differently. A tool whose Xcode path was only unit-tested would be a
/// tool that has never run an Xcode project.
///
/// The fixture is a Swift package rather than an `.xcodeproj`, because xcodebuild builds
/// one directly with a scheme it synthesises - and a `.pbxproj` checked into this
/// repository would be a file nobody here can maintain and Xcode rewrites on sight.
@Suite("Driving xcodebuild")
struct XcodeDriverTests {

    struct Fixture {
        let root: URL
        let derivedData: URL
        let scratch: URL

        func cleanUp() {
            for directory in [root, derivedData, scratch] {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// A package with one test that passes and a guard that can be woken, which is the
    /// smallest thing that can show a mutant behaving differently through a document.
    static func fixture() throws -> Fixture {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-xcode-\(identifier)")
        let fixture = Fixture(
            root: root,
            derivedData: FileManager.default.temporaryDirectory
                .appending(path: "swift-mutants-xcode-dd-\(identifier)"),
            scratch: FileManager.default.temporaryDirectory
                .appending(path: "swift-mutants-xcode-scratch-\(identifier)")
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
        // The guard the instrumenter would have written, spelled by hand: this is about
        // xcodebuild carrying the variable, not about instrumenting.
        try Self.write(
            """
            #if canImport(Darwin)
            import Darwin
            #else
            import Glibc
            #endif

            private let __sm_active: UInt32 = {
                guard let text = getenv("SWIFT_MUTANTS_ACTIVE"),
                    let index = UInt32(String(cString: text))
                else { return .max }
                return index
            }()

            public func atLeast(_ value: Int, _ limit: Int) -> Bool {
                __sm_active == 7 ? (value > limit) : (value >= limit)
            }
            """, to: root.appending(path: "Sources/Subject/Subject.swift"))
        try Self.write(
            """
            import Testing

            @testable import Subject

            @Test func boundary() { #expect(atLeast(3, 3)) }
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

    static func driver(_ fixture: Fixture) -> XcodeDriver {
        XcodeDriver(
            root: fixture.root,
            runner: Runner(recorder: TraceRecorder()),
            environment: Self.environment()
        )
    }

    static let destination = "platform=macOS"

    @Test("reads the schemes xcodebuild says a package has", .tags(.toolchain))
    func readsSchemes() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let schemes = try await Self.driver(fixture).schemes()
        #expect(schemes.contains("Subject-Package"))
    }

    /// The whole bargain, end to end: build once, then wake one mutant through a copy of
    /// the document and see the suite notice.
    ///
    /// Both directions, because only the pair says the variable is doing anything. With
    /// nothing awake the test passes; with the mutant awake the same command fails, through
    /// the same build.
    @Test("builds once and wakes one mutant through the document", .tags(.toolchain))
    func buildsOnceAndWakesOne() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let driver = Self.driver(fixture)

        let document = try await driver.buildForTesting(
            scheme: "Subject-Package",
            destination: Self.destination,
            derivedData: fixture.derivedData
        )
        #expect(document.lastPathComponent.hasSuffix(".xctestrun"))

        let asleep = try await driver.test(
            xctestrun: document,
            destination: Self.destination,
            resultBundle: fixture.scratch.appending(path: "asleep.xcresult"),
            onlyTests: nil
        )
        #expect(!asleep.anythingFailed)
        #expect(asleep.started.count == 1)

        let woken = try Xctestrun(contentsOf: document)
            .waking(["SWIFT_MUTANTS_ACTIVE": "7"])
            .write(named: "mutant-7")
        let awake = try await driver.test(
            xctestrun: woken,
            destination: Self.destination,
            resultBundle: fixture.scratch.appending(path: "awake.xcresult"),
            onlyTests: nil
        )
        #expect(awake.anythingFailed)
        #expect(awake.failed.count == 1)
        // And the same build served both, which is what makes this worth doing at all.
        #expect(awake.started == asleep.started)
    }

    /// A project that will not build is a thing to say plainly. Every later complaint would
    /// otherwise be about something swift-mutants did.
    @Test("says so when xcodebuild will not build the project", .tags(.toolchain))
    func saysWhenItWillNotBuild() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        try Self.write(
            "public func atLeast(_ value: Int) -> Bool { value >= }",
            to: fixture.root.appending(path: "Sources/Subject/Subject.swift"))
        await #expect(throws: XcodeDriver.Refused.self) {
            try await Self.driver(fixture).buildForTesting(
                scheme: "Subject-Package",
                destination: Self.destination,
                derivedData: fixture.derivedData
            )
        }
    }
}

extension Tag {
    /// Needs Xcode, not only a Swift toolchain.
    @Tag static var toolchain: Self
}

/// Deciding a mutant through Xcode, the way the scheduler will.
///
/// The driver tests prove that xcodebuild does what this expects. This proves the shape the
/// scheduler sees: the same `Verdict` the SwiftPM path produces, from a run that has no
/// event stream to watch.
///
/// Both directions every time. A host that woke nothing and one that woke everything both
/// look right from one side: with nothing awake the suite passes, which is also what a
/// mutant nothing catches looks like. Only the pair says the variable did anything.
@Suite("Deciding a mutant through Xcode")
struct XcodeHostTests {

    static func host(_ fixture: XcodeDriverTests.Fixture, document: URL) throws -> XcodeHost {
        XcodeHost(
            driver: XcodeDriverTests.driver(fixture),
            document: try Xctestrun(contentsOf: document),
            destination: XcodeDriverTests.destination,
            scratch: fixture.scratch,
            worker: 3
        )
    }

    /// Builds the fixture once and hands back a host over it.
    static func built() async throws -> (fixture: XcodeDriverTests.Fixture, host: XcodeHost) {
        let fixture = try XcodeDriverTests.fixture()
        let document = try await XcodeDriverTests.driver(fixture).buildForTesting(
            scheme: "Subject-Package",
            destination: XcodeDriverTests.destination,
            derivedData: fixture.derivedData
        )
        return (fixture, try Self.host(fixture, document: document))
    }

    @Test(
        "says a mutant nothing catches survived, and one something catches killed",
        .tags(.toolchain))
    func bothDirections() async throws {
        let (fixture, host) = try await Self.built()
        defer { fixture.cleanUp() }

        let asleep = await host.run(activating: nil)
        #expect(asleep.outcome == .survived)
        #expect(asleep.startedTests.count == 1)
        #expect(asleep.killedBy.isEmpty)

        // Mutant 7 is the one the fixture's guard switches on, and the fixture's test
        // asserts the behaviour it changes.
        let awake = await host.run(activating: 7)
        #expect(awake.outcome == .killed)
        #expect(awake.killedBy.count == 1)
        #expect(awake.firstFailure != nil)
    }

    /// A mutant nothing is awake for is not the same as a mutant nothing reaches, and a
    /// mutant whose index no guard switches on is the second: the suite passes, and that is
    /// a real survival rather than a run that did nothing.
    @Test("says a mutant no guard answers to survived", .tags(.toolchain))
    func anIndexNothingAnswersTo() async throws {
        let (fixture, host) = try await Self.built()
        defer { fixture.cleanUp() }

        let verdict = await host.run(activating: 9999)
        #expect(verdict.outcome == .survived)
        #expect(verdict.startedTests.count == 1)
    }

    /// A filter that matches nothing starts no tests, and a run that started none
    /// established nothing. Reading it as a survivor is how a mutant nothing ran against
    /// goes into a report as a gap somebody should write a test for.
    @Test("says nothing was established when no test ran", .tags(.toolchain))
    func noTestsIsNotSurvival() async throws {
        let (fixture, host) = try await Self.built()
        defer { fixture.cleanUp() }

        let verdict = await host.run(
            activating: 7, onlyTests: ["SubjectTests/NoSuchTest/doesNotExist()"])
        #expect(verdict.outcome == .errored)
        #expect(verdict.startedTests.isEmpty)
    }

    /// Two workers must not write one document, or each would wake the other's mutant -
    /// and the run would still finish, with a score about a program nobody ran.
    @Test("calls one worker's document something else than another's", .tags(.toolchain))
    func documentsArePerWorker() async throws {
        let (fixture, host) = try await Self.built()
        defer { fixture.cleanUp() }
        let other = XcodeHost(
            driver: XcodeDriverTests.driver(fixture),
            document: try Xctestrun(
                contentsOf: XcodeProject.xctestrun(
                    in: fixture.derivedData.appending(path: "Build/Products"))),
            destination: XcodeDriverTests.destination,
            scratch: fixture.scratch,
            worker: 4
        )
        #expect(host.documentName != other.documentName)
        #expect(host.documentName.contains("3"))
        #expect(other.documentName.contains("4"))
    }
}
