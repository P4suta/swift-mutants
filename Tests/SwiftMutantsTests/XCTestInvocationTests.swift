// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutants

@Suite("XCTest invocation results")
struct XCTestInvocationTests {
    @Test("mixed framework results preserve XCTest outcomes", arguments: 0..<3, [false, true])
    func mixed(status: Int, declaredSkip: Bool) async throws {
        let content = status == 1 ? "<failure/>" : (status == 2 && declaredSkip ? "<skipped/>" : "")
        let xml =
            "<testsuite><testcase classname='Suite' name='test'>\(content)</testcase></testsuite>"
        let label = ["passed", "failed", "skipped"][status]
        let output = "Test Case '-[Suite test]' \(label) (0.001 seconds)."
        let fixture = try TestInvocationFixture(
            xctest: xml, status: status == 1 ? 1 : 0, output: output)
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        #expect(observation.diagnostic == nil)
        let xctest = TestIdentity(framework: "Fixture:xctest", className: "Suite", name: "test")
        let testing = TestIdentity(framework: "Fixture:testing", className: "Suite", name: "test")
        let expected = XUnitResults(
            executed: status == 2 ? [testing: 1] : [testing: 1, xctest: 1],
            skipped: status == 2 ? [xctest: 1] : [:],
            failures: status == 1 ? 1 : 0)
        #expect(observation.results == expected)
        #expect(observation.verdict(comparedTo: expected) == (status == 1 ? .killed : .survived))
        let arguments = try String(
            contentsOf: fixture.root.appending(path: "arguments"), encoding: .utf8)
        #expect(arguments.split(separator: "\n").contains("--verbose"))
    }

    @Test("completion records remain separate across unterminated output streams")
    func outputStreams() async throws {
        let fixture = try TestInvocationFixture(
            xctest: TestInvocationFixture.passing,
            output: "Test Case '-[Suite test]' passed (0.001 seconds).",
            errors: "diagnostic without a line ending")
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        #expect(observation.diagnostic == nil)
        #expect(observation.results.executed.count == 2)
    }

    @Test("framework errors invalidate assertion failures", arguments: [0, 1])
    func frameworkErrors(status: Int) async throws {
        let xml = "<testsuite><testcase name='test'><failure/><error/></testcase></testsuite>"
        let fixture = try TestInvocationFixture(testing: xml, status: status)
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        #expect(observation.diagnostic != nil)
        #expect(observation.verdict(comparedTo: observation.results) == .invalidEvidence)
    }

    @Test("elapsed suite time retains whole and fractional seconds")
    func elapsedDuration() async throws {
        let fixture = try TestInvocationFixture(delay: true)
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .milliseconds(1_250))
        #expect(observation.timedOut)
        #expect(observation.durationMilliseconds >= 1_250)
    }
}
