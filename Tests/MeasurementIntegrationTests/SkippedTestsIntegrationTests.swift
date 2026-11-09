// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutants
import Testing

@Suite("Skipped test compatibility", .serialized)
struct SkippedTestsIntegrationTests {
    @Test("measures suites with passing and skipped tests")
    func mixedSkipping() async throws {
        let tests =
            PackageFixture.testing + """

                @Test(.disabled("fixture")) func skipped() {
                    Issue.record("A disabled test executed")
                }
                """
        let package = try PackageFixture(tests: tests)
        defer { try? package.remove() }
        let report = try await MutationTesting.run(packageAt: package.root)
        #expect(report.summary.killed > 0)
        #expect(report.summary.survived > 0)
        #expect(report.summary.errored == 0)
        #expect(report.score != nil)
    }

    @Test("a mixed suite keeps completion evidence for entirely skipped XCTest cases")
    func skippedXCTest() async throws {
        let tests =
            PackageFixture.testing + """

                import XCTest
                final class SkippedTests: XCTestCase {
                    func testSkipped() throws { throw XCTSkip("fixture") }
                }
                """
        let package = try PackageFixture(tests: tests)
        defer { try? package.remove() }
        let report = try await MutationTesting.run(packageAt: package.root)
        #expect(report.summary.killed > 0)
        #expect(report.summary.survived > 0)
        #expect(report.summary.errored == 0)
        #expect(report.score != nil)
    }

    @Test("changed test inventory explains an inconclusive assertion failure")
    func changedInventory() async throws {
        let tests = """
            import Testing
            import Subject
            @Test(.enabled(if: enabled())) func conditional() {}
            @Test func assertion() { #expect(enabled()) }
            """
        let package = try PackageFixture(
            tests: tests, source: "public func enabled() -> Bool { true }")
        defer { try? package.remove() }
        let report = try await MutationTesting.run(packageAt: package.root)
        #expect(report.results.map(\.outcome) == [.errored])
        #expect(report.results.first?.diagnostic?.contains("which tests") == true)
        #expect(report.score == nil)
    }
}
