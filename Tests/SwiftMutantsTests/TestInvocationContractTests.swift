// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutants

@Suite("SwiftPM test invocation contracts")
struct TestInvocationContractTests {
    @Test("valid exit codes agree with recorded failures", arguments: [false, true])
    func validResult(failed: Bool) async throws {
        let fixture = try TestInvocationFixture(
            testing: failed ? TestInvocationFixture.failing : TestInvocationFixture.passing,
            status: failed ? 1 : 0
        )
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        #expect(observation.diagnostic == nil)
        #expect(!observation.timedOut)
        #expect(observation.results.executed.count == 1)
        #expect(observation.results.failures == (failed ? 1 : 0))
        #expect(
            observation.verdict(comparedTo: observation.results) == (failed ? .killed : .survived))
    }

    @Test(
        "missing, malformed, and inconsistent results are inconclusive",
        arguments: [
            (nil as String?, TestInvocationFixture.empty as String?, 0),
            (TestInvocationFixture.passing as String?, nil as String?, 0),
            ("<broken>" as String?, TestInvocationFixture.empty as String?, 0),
            (TestInvocationFixture.failing as String?, TestInvocationFixture.empty as String?, 0),
            (TestInvocationFixture.passing as String?, TestInvocationFixture.empty as String?, 1),
            (TestInvocationFixture.passing as String?, TestInvocationFixture.empty as String?, 2),
        ]
    )
    func invalidResult(testing: String?, xctest: String?, status: Int) async throws {
        let fixture = try TestInvocationFixture(testing: testing, xctest: xctest, status: status)
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        #expect(observation.diagnostic != nil)
        #expect(observation.verdict(comparedTo: observation.results) == .invalidEvidence)
    }

    @Test(
        "SwiftPM abnormal-exit diagnostics override otherwise valid failure XML",
        arguments: [
            "error: Process '/fixture' exited with unexpected signal code 5",
            "error: Exited with signal code 5",
            "error: Test process exited with signal 5",
        ]
    )
    func abnormalExit(message: String) async throws {
        let fixture = try TestInvocationFixture(
            testing: TestInvocationFixture.failing, status: 1, errors: message)
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        #expect(observation.diagnostic?.contains(message) == true)
        #expect(observation.verdict(comparedTo: observation.results) == .invalidEvidence)
    }

    @Test("quoted diagnostic text in a verbose test argument isn't an abnormal exit")
    func quotedDiagnostic() async throws {
        let output =
            "Test case passing argument message -> \"error: Exited with signal code 5\" started."
        let fixture = try TestInvocationFixture(output: output)
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        #expect(observation.diagnostic == nil)
        #expect(observation.verdict(comparedTo: observation.results) == .survived)
    }

    @Test("a quoted XCTest completion in verbose arguments isn't a completion record")
    func quotedCompletion() async throws {
        let output =
            "Test case passing argument -> \"Test Case '-[Suite test]' passed (0.01 seconds).\""
        let fixture = try TestInvocationFixture(output: output)
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5))
        let hasDiagnostic = observation.diagnostic != nil
        #expect(!hasDiagnostic)
        #expect(observation.verdict(comparedTo: observation.results) == .survived)
    }

    @Test("products merge identities without conflating frameworks")
    func products() async throws {
        let fixture = try TestInvocationFixture()
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product("First"), fixture.product("Second")], budget: .seconds(5))
        #expect(observation.diagnostic == nil)
        #expect(
            Set(observation.results.executed.keys.map(\.framework)) == [
                "First:testing", "Second:testing",
            ])
    }

    @Test("an invalid product result stops subsequent products")
    func invalidProductStops() async throws {
        let fixture = try TestInvocationFixture(testing: nil)
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product("First"), fixture.product("Second")], budget: .seconds(5))
        #expect(observation.diagnostic != nil)
        let arguments = try String(
            contentsOf: fixture.root.appending(path: "arguments"), encoding: .utf8)
        #expect(arguments.contains("First\n"))
        #expect(!arguments.contains("Second\n"))
    }

    @Test("an exhausted suite budget starts no test process")
    func exhaustedBudget() async throws {
        let fixture = try TestInvocationFixture()
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .zero)
        #expect(observation.timedOut)
        #expect(observation.results.executed.isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: fixture.root.appending(path: "arguments").path))
    }

    @Test("a test command that can't start is inconclusive")
    func startFailure() async throws {
        let fixture = try TestInvocationFixture()
        defer { try? fixture.clean() }
        let session = try MeasurementSession(
            package: fixture.root,
            options: RunOptions(),
            progress: { _ in },
            executable: "/nonexistent/swift-mutants-fixture"
        )
        defer { try? session.clean() }
        let observation = try await session.test(products: [fixture.product()], budget: .seconds(5))
        #expect(observation.diagnostic?.contains("Couldn't start the command") == true)
        #expect(observation.results.executed.isEmpty)
    }

    @Test("activation and test selection reach SwiftPM unchanged")
    func arguments() async throws {
        let fixture = try TestInvocationFixture(
            activation: "17", options: RunOptions(filter: ["selected test"], skip: ["omitted test"])
        )
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5), activation: 17)
        #expect(observation.diagnostic == nil)
        let arguments = try String(
            contentsOf: fixture.root.appending(path: "arguments"), encoding: .utf8)
        #expect(arguments.contains("swift\ntest\n--skip-build\n"))
        #expect(arguments.contains("--test-product\nFixture\n"))
        #expect(arguments.contains("--filter\nselected test\n--skip\nomitted test\n"))
    }

    @Test(
        "transcript verbosity follows the observed framework requirement", arguments: [false, true])
    func verbosity(verbose: Bool) async throws {
        let fixture = try TestInvocationFixture()
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product()], budget: .seconds(5), verbose: verbose)
        #expect(observation.diagnostic == nil)
        let arguments = try String(
            contentsOf: fixture.root.appending(path: "arguments"), encoding: .utf8)
        #expect(arguments.split(separator: "\n").contains("--verbose") == verbose)
    }

    @Test("the suite deadline stops subsequent products")
    func deadline() async throws {
        let fixture = try TestInvocationFixture(delay: true)
        defer { try? fixture.clean() }
        let observation = try await fixture.session.test(
            products: [fixture.product("First"), fixture.product("Second")],
            budget: .milliseconds(200))
        #expect(observation.timedOut)
        #expect(observation.verdict(comparedTo: observation.results) == .timedOut)
        let arguments = try String(
            contentsOf: fixture.root.appending(path: "arguments"), encoding: .utf8)
        #expect(arguments.contains("First\n"))
        #expect(!arguments.contains("Second\n"))
    }

    @Test("baselines reject failures, errors, deadlines, empty suites, and changed inventories")
    func baseline() throws {
        let fixture = try TestInvocationFixture()
        defer { try? fixture.clean() }
        let identity = TestIdentity(framework: "fixture", className: "Suite", name: "test")
        let results = XUnitResults(executed: [identity: 1])
        let valid = TestObservation(results: results)
        try fixture.session.requireBaseline(valid)
        try fixture.session.requireBaseline(valid, matching: results)
        let invalid = [
            TestObservation(results: XUnitResults(executed: [identity: 1], failures: 1)),
            TestObservation(results: XUnitResults(executed: [identity: 1], errors: 1)),
            TestObservation(results: results, timedOut: true),
            TestObservation(results: results, diagnostic: "fixture failure"),
            TestObservation(),
            TestObservation(results: XUnitResults(executed: [identity: 2])),
            TestObservation(results: XUnitResults(executed: [identity: 1], skipped: [identity: 1])),
        ]
        for observation in invalid {
            #expect(throws: MutationTestingError.self) {
                try fixture.session.requireBaseline(observation, matching: results)
            }
        }
    }
}
