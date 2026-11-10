// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutants

@Suite("Diagnostic retention")
struct DiagnosticRetentionTests {
    private static let truncationPrefix =
        "XCTest output exceeded the diagnostic retention limit of \(TestInvocationFixture.outputLimit) bytes for Fixture."

    @Test(
        "XCTest records beyond retention can't disappear behind an empty XML inventory",
        arguments: [false, true])
    func unrecordedXCTest(stderr: Bool) async throws {
        let output =
            String(repeating: "x", count: TestInvocationFixture.outputLimit + 1)
            + "\nTest Case '-[Suite missing]' passed (0.01 seconds).\n"
        let fixture = try TestInvocationFixture(
            output: stderr ? "" : output,
            errors: stderr ? output : "")
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        #expect(!observation.timedOut)
        #expect(observation.diagnostic?.hasPrefix(Self.truncationPrefix) == true)
        #expect(observation.verdict(comparedTo: observation.results) == .invalidEvidence)
    }

    @Test(
        "complete Swift Testing failures survive diagnostic truncation", arguments: [false, true])
    func truncatedOutput(stderr: Bool) async throws {
        let output = String(repeating: "x", count: TestInvocationFixture.outputLimit + 1)
        let fixture = try TestInvocationFixture(
            testing: TestInvocationFixture.failing,
            status: 1,
            output: stderr ? "" : output,
            errors: stderr ? output : ""
        )
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        let timedOut = observation.timedOut
        #expect(!timedOut)
        let hasDiagnostic = observation.diagnostic != nil
        #expect(!hasDiagnostic)
        #expect(observation.results.failures == 1)
        #expect(observation.verdict(comparedTo: observation.results) == .killed)
    }

    @Test(
        "late abnormal exits override complete XML beyond retained diagnostics",
        arguments: [false, true])
    func lateCrash(stderr: Bool) async throws {
        let output =
            String(repeating: "x", count: TestInvocationFixture.outputLimit + 1)
            + "\nerror: Process '/tool' exited with unexpected signal code 5\n"
        let fixture = try TestInvocationFixture(
            testing: TestInvocationFixture.failing,
            status: 1,
            output: stderr ? "" : output,
            errors: stderr ? output : ""
        )
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        let timedOut = observation.timedOut
        #expect(!timedOut)
        let explainsExit =
            observation.diagnostic?.hasPrefix(
                "SwiftPM reported an abnormal test process exit.") == true
        #expect(explainsExit)
        #expect(observation.verdict(comparedTo: observation.results) == .invalidEvidence)
    }

    @Test(
        "XCTest completion transcripts remain mandatory after truncation",
        arguments: [false, true], [false, true])
    func truncatedXCTest(stderr: Bool, completionAfterLimit: Bool) async throws {
        let completion = "Test Case '-[Suite test]' failed (0.01 seconds).\n"
        let noise = String(repeating: "x", count: TestInvocationFixture.outputLimit + 1)
        let transcript = completionAfterLimit ? noise + "\n" + completion : completion + noise
        let fixture = try TestInvocationFixture(
            testing: TestInvocationFixture.empty,
            xctest:
                "<testsuite tests='1' failures='1'><testcase classname='Suite' name='test'><failure/></testcase></testsuite>",
            status: 1,
            output: stderr ? "" : transcript,
            errors: stderr ? transcript : ""
        )
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        let timedOut = observation.timedOut
        #expect(!timedOut)
        #expect(observation.diagnostic?.hasPrefix(Self.truncationPrefix) == true)
        #expect(observation.verdict(comparedTo: observation.results) == .invalidEvidence)
    }
}
