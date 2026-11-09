// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutants

@Suite("Measurement results")
struct MeasurementTests {
    @Test("a source removed by tests retains its failure stage")
    func missingSource() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "swift-mutants-missing-source-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "manifest".write(
            to: root.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let source = "let ready = true"
        try source.write(
            to: root.appending(path: "Subject.swift"),
            atomically: true,
            encoding: .utf8
        )
        let session = try MeasurementSession(
            package: root,
            options: RunOptions(),
            progress: { _ in }
        )
        defer { try? session.clean() }
        try FileManager.default.removeItem(
            at: session.temporary.appending(path: "package/Subject.swift")
        )
        do {
            try session.verifySnapshot(
                expectedSources: ["Subject.swift": source],
                state: session.snapshot,
                stage: .baseline
            )
            Issue.record("A missing source was accepted")
        } catch let error as MutationTestingError {
            #expect(error.stage == .baseline)
        }
    }

    @Test("only kills and survivors contribute to a complete score")
    func score() throws {
        let mutation = try #require(
            try Mutation.discover(in: "func f() -> Bool { true }", at: "Subject.swift").first
        )
        func report(_ outcomes: [MutationOutcome]) -> MutationReport {
            MutationReport(
                results: outcomes.map { MutationResult(mutation: mutation, outcome: $0) }
            )
        }
        #expect(report([.killed, .survived, .rejected]).score == 0.5)
        #expect(report([.rejected]).score == nil)
        #expect(report([]).score == nil)
        #expect(report([.killed, .timedOut]).score == nil)
        #expect(report([.killed, .errored]).score == nil)
    }

    @Test("reads failure, skip, and execution identities from XML")
    func xml() throws {
        let document = """
            <testsuites><testsuite tests="3" failures="1" errors="0">
            <testcase classname="Tests" name="pass"/>
            <testcase classname="Tests" name="fail"><failure message="assertion"/></testcase>
            <testcase classname="Tests" name="skip"><skipped/></testcase>
            </testsuite></testsuites>
            """
        let results = try XUnitResults.parse(Data(document.utf8), framework: "xctest")
        #expect(results.executed.count == 2)
        #expect(results.failures == 1)
        #expect(results.skipped.count == 1)
    }

    @Test(
        "refuses malformed or unrecognized XML",
        arguments: [
            "", "<testsuites>", "<other/>",
            "<testsuite tests=\"1\"><testcase/></testsuite>",
            "<testsuite tests=\"2\"><testcase name=\"one\"/></testsuite>",
            "<testsuite tests=\"0\" failures=\"1\"/>",
            "<testsuite tests=\"1\" errors=\"1\"><testcase name=\"one\"/></testsuite>",
            "<!DOCTYPE testsuite [<!ENTITY external SYSTEM 'file:///etc/passwd'>]><testsuite/>",
        ]
    )
    func invalidXML(document: String) {
        #expect(throws: (any Error).self) {
            try XUnitResults.parse(Data(document.utf8), framework: "testing")
        }
    }

    @Test("XCTest completion records distinguish skipped tests and crashes")
    func xctestCompletions() throws {
        let xml = Data(
            "<testsuite tests=\"1\" failures=\"0\"><testcase classname=\"Module.Tests\" name=\"testSkip\"/></testsuite>"
                .utf8
        )
        var results = try XUnitResults.parse(xml, framework: "xctest")
        try XCTestTranscript.reconcile(
            &results,
            output: "Test Case '-[Module.Tests testSkip]' skipped (0.01 seconds).",
            framework: "xctest"
        )
        #expect(results.executed.isEmpty)
        #expect(results.skipped.count == 1)
        var crashed = try XUnitResults.parse(xml, framework: "xctest")
        #expect(throws: (any Error).self) {
            try XCTestTranscript.reconcile(
                &crashed,
                output: "Test Case '-[Module.Tests testSkip]' started.",
                framework: "xctest"
            )
        }
    }
}
