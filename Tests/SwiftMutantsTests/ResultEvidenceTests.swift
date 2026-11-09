// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutants

@Suite("Trustworthy test evidence")
struct ResultEvidenceTests {
    private static let one = "<testcase classname=\"Suite\" name=\"one\"/>"
    private static let two = "<testcase classname=\"Suite\" name=\"two\"/>"
    private static let skipped =
        "<testcase classname=\"Suite\" name=\"skipped\"><skipped/></testcase>"
    private static let failed =
        "<testcase classname=\"Suite\" name=\"one\"><failure message=\"assertion\"/></testcase>"

    @Test(
        "a recorded failure doesn't conceal changed test inventory",
        arguments: ["missing", "extra", "skip", "repeat"]
    )
    func changedInventory(kind: String) throws {
        let baseline = try Self.results(Self.one + Self.two + Self.skipped)
        let cases: String
        switch kind {
        case "missing": cases = Self.failed + Self.skipped
        case "extra":
            cases = Self.failed + Self.two + Self.skipped + "<testcase name=\"extra\"/>"
        case "skip":
            cases = Self.failed + Self.two + "<testcase classname=\"Suite\" name=\"skipped\"/>"
        default: cases = Self.failed + Self.one + Self.two + Self.skipped
        }
        let observation = TestObservation(results: try Self.results(cases))
        #expect(observation.verdict(comparedTo: baseline).outcome == .errored)
    }

    @Test("complete matching suites distinguish failures from survivors")
    func completeInventory() throws {
        let baseline = try Self.results(Self.one + Self.two + Self.skipped)
        let failed = TestObservation(
            results: try Self.results(Self.failed + Self.two + Self.skipped))
        #expect(failed.verdict(comparedTo: baseline).outcome == .killed)
        #expect(
            TestObservation(results: baseline).verdict(comparedTo: baseline).outcome == .survived)
    }

    @Test("supports both total and started test counts", arguments: [1, 2])
    func skippedCounts(tests: Int) throws {
        let parsed = try Self.results(
            Self.one + Self.skipped,
            attributes: "tests=\"\(tests)\" skipped=\"1\" failures=\"0\" errors=\"0\""
        )
        #expect(parsed.executed.count == 1)
        #expect(parsed.skipped.count == 1)
    }

    @Test(
        "rejects misplaced XML control elements",
        arguments: [
            "<testsuites><testcase name=\"one\"/></testsuites>",
            "<testsuite><wrapper><testcase name=\"one\"/></wrapper></testsuite>",
            "<testsuites><wrapper><testsuite/></wrapper></testsuites>",
            "<testsuite><testcase name=\"one\"><wrapper><failure/></wrapper></testcase></testsuite>",
            "<testsuite><testcase name=\"one\"><failure><error/></failure></testcase></testsuite>",
            "<testsuite><testcase name=\"one\"><skipped/><skipped/></testcase></testsuite>",
        ]
    )
    func malformedStructure(document: String) {
        #expect(throws: (any Error).self) {
            try XUnitResults.parse(Data(document.utf8), framework: "fixture")
        }
    }

    @Test("test identity fields don't collide across delimiters")
    func distinctIdentities() throws {
        let first = "<testcase classname=\"A/B\" name=\"C\"/>"
        let second = "<testcase classname=\"A\" name=\"B/C\"/>"
        let parsed = try Self.results(first + second)
        #expect(parsed.executed.count == 2)
        #expect(try Self.results(first).executed != Self.results(second).executed)
    }

    private static func results(_ cases: String, attributes: String = "") throws -> XUnitResults {
        let document = "<testsuite \(attributes)>\(cases)</testsuite>"
        return try XUnitResults.parse(Data(document.utf8), framework: "fixture")
    }
}
