// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import SwiftMutants
import Testing

@Suite("Measurement failure boundaries", .serialized)
struct FailureIntegrationTests {
    @Test("a guard failure falls back to a valid individual edit")
    func guardFailure() async throws {
        let source = """
            public protocol Value {}
            public struct Input { public init() {} }
            public struct Sum: Value {}
            public struct Difference: Value {}
            public func + (_ a: Input, _ b: Input) -> Sum { Sum() }
            public func - (_ a: Input, _ b: Input) -> Difference { Difference() }
            public func combine(_ a: Input, _ b: Input) -> some Value { a + b }
            """
        let tests = """
            import Testing
            import Subject
            @Test func typeIsSum() {
                #expect(String(describing: type(of: combine(Input(), Input()))) == "Sum")
            }
            """
        let package = try PackageFixture(tests: tests, source: source)
        defer { try? package.remove() }
        let report = try await MutationTesting.run(packageAt: package.root)
        #expect(report.results.map(\.outcome) == [.killed])
    }

    @Test("only an invalid individual edit becomes a compiler rejection")
    func rejected() async throws {
        let source = "public func join(_ a: String, _ b: String) -> String { a + b }"
        let tests = """
            import Testing
            import Subject
            @Test func joins() { #expect(join("a", "b") == "ab") }
            """
        let package = try PackageFixture(tests: tests, source: source)
        defer { try? package.remove() }
        let report = try await MutationTesting.run(packageAt: package.root)
        #expect(report.results.map(\.outcome) == [.rejected])
        #expect(report.results.first?.diagnostic?.contains("error:") == true)
        #expect(report.score == nil)
    }

    @Test("a mutation deadline leaves the score absent")
    func timedOut() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(
            path: "swift-mutants-timeout-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let package = try PackageFixture(
            tests: Self.loopingTests(marker: marker),
            source: "public func finished() -> Bool { true }"
        )
        defer { try? package.remove() }
        let report = try await MutationTesting.run(
            packageAt: package.root,
            options: RunOptions(timeout: .seconds(15))
        )
        #expect(report.results.map(\.outcome) == [.timedOut])
        #expect(report.score == nil)
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
    }

    @Test("public API cancellation returns after the test child exits")
    func cancellation() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(
            path: "swift-mutants-api-cancel-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let package = try PackageFixture(
            tests: Self.loopingTests(marker: marker),
            source: "public func finished() -> Bool { true }"
        )
        defer { try? package.remove() }
        let task = Task {
            try await MutationTesting.run(
                packageAt: package.root,
                options: RunOptions(timeout: .seconds(60))
            )
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(60)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation returned a report")
        } catch is CancellationError {
            #expect(kill(pid, 0) == -1)
        }
    }

    private static func loopingTests(marker: URL) -> String {
        """
        import Darwin
        import Foundation
        import Testing
        import Subject
        @Test func finishes() async throws {
            if !finished() {
                try String(getpid()).write(toFile: \(String(reflecting: marker.path)), atomically: true, encoding: .utf8)
            }
            while !finished() { try await Task.sleep(for: .milliseconds(10)) }
        }
        """
    }

    @Test("a test process crash is an execution error", arguments: [false, true])
    func crash(xctest: Bool) async throws {
        let body = "if !finished() { fatalError(\"fixture crash\") }"
        let tests =
            xctest
            ? """
            import XCTest
            import Subject
            final class CrashTests: XCTestCase { func testCrash() { \(body) } }
            """
            : """
            import Testing
            import Subject
            @Test func crash() { \(body) }
            """
        let package = try PackageFixture(
            tests: tests,
            source: "public func finished() -> Bool { true }"
        )
        defer { try? package.remove() }
        let report = try await MutationTesting.run(packageAt: package.root)
        #expect(report.results.map(\.outcome) == [.errored])
        #expect(report.score == nil)
    }

    @Test(
        "an entirely skipped suite stops at baseline",
        arguments: [
            "import Testing\n@Test(.disabled(\"fixture\")) func skipped() {}",
            "import XCTest\nfinal class SkipTests: XCTestCase { func testSkip() throws { throw XCTSkip(\"fixture\") } }",
        ]
    )
    func allSkipped(tests: String) async throws {
        let package = try PackageFixture(tests: tests)
        defer { try? package.remove() }
        do {
            _ = try await MutationTesting.run(packageAt: package.root)
            Issue.record("An entirely skipped suite was accepted")
        } catch let error as MutationTestingError {
            #expect(error.stage == .baseline)
        }
    }

    @Test(
        "a red baseline and a filter selecting no tests stop measurement",
        arguments: [false, true]
    )
    func invalidBaseline(filtered: Bool) async throws {
        let tests =
            filtered
            ? PackageFixture.testing : "import Testing\n@Test func fails() { #expect(Bool(false)) }"
        let package = try PackageFixture(tests: tests)
        defer { try? package.remove() }
        do {
            _ = try await MutationTesting.run(
                packageAt: package.root,
                options: RunOptions(filter: filtered ? ["NoSuchTest"] : [])
            )
            Issue.record("An invalid baseline was accepted")
        } catch let error as MutationTestingError {
            #expect(error.stage == .baseline)
        }
    }
}
