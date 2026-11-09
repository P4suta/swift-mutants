// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutants
import Testing

@testable import SwiftMutantsCLI

@Suite("CLI measurement contract")
struct ReportRenderingTests {
    @Test("separates strict survivors from incomplete measurements")
    func status() throws {
        let mutation = try #require(
            try Mutation.discover(in: "let value = true", at: "Subject.swift").first)
        func report(_ outcomes: [MutationOutcome]) -> MutationReport {
            MutationReport(
                results: outcomes.map { MutationResult(mutation: mutation, outcome: $0) })
        }
        #expect(ReportRendering.status(report([.killed]), strict: true) == 0)
        #expect(ReportRendering.status(report([.survived]), strict: false) == 0)
        #expect(ReportRendering.status(report([.survived]), strict: true) == 1)
        #expect(ReportRendering.status(report([.survived, .timedOut]), strict: true) == 2)
        #expect(ReportRendering.status(report([.errored]), strict: false) == 2)
        #expect(ReportRendering.status(report([.rejected]), strict: false) == 2)
        #expect(ReportRendering.status(report([]), strict: false) == 2)
    }

    @Test("renders survivor location and replacement and includes all results in JSON")
    func rendering() throws {
        let mutation = try #require(
            try Mutation.discover(in: "let value = true", at: "Subject.swift").first)
        let report = MutationReport(results: [
            MutationResult(mutation: mutation, outcome: .survived)
        ])
        let text = ReportRendering.report(report)
        #expect(text.contains("Subject.swift:1:"))
        #expect(text.contains("\"true\" -> \"false\""))
        let data = try #require(try ReportRendering.json(report).data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 3)
        #expect((object["results"] as? [[String: Any]])?.count == 1)
        let counts = try #require(object["summary"] as? [String: Int])
        #expect(counts["total"] == 1)
        #expect(counts["survived"] == 1)
    }

    @Test("unscored reports encode an explicit null", arguments: MutationOutcome.allCases)
    func scoreEncoding(outcome: MutationOutcome) throws {
        let mutation = try #require(
            try Mutation.discover(in: "let value = true", at: "Subject.swift").first)
        let report = MutationReport(results: [MutationResult(mutation: mutation, outcome: outcome)])
        let data = Data(try ReportRendering.json(report).utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if outcome == .killed || outcome == .survived {
            #expect(object["score"] as? Double == report.score)
        } else {
            #expect(object["score"] is NSNull)
        }
    }
}
