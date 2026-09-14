// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsReport
import SwiftMutantsTestKit
import Testing

/// The report a real run produces.
///
/// Everything about the shape is settled by unit tests over a fixture. What is not settled
/// there is whether a run actually carries what the shape needs - a report can be perfectly
/// formed and say `null` for every position because nothing ever put the line index in it,
/// and a fixture that supplies the index by hand would never notice.
@Suite("A report of a real run")
struct ReportIntegrationTests {

    @Test("says where every mutant is, from a run that read the files", .tags(.integration))
    func saysWhereEveryMutantIs() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let outcome = try await RunIntegrationTests.run(fixture)
        let report = RunReport(of: outcome)

        #expect(!report.mutants.isEmpty)
        // Every one of them, not most: a position that went missing would be a report
        // naming a place nobody can open.
        #expect(report.mutants.allSatisfy { $0.line.value != nil })
        #expect(report.mutants.allSatisfy { ($0.line.value ?? 0) > 0 })
        #expect(report.mutants.allSatisfy { ($0.column.value ?? 0) > 0 })
    }

    /// The counts in the report are the run's counts, not a recount of the list - and the
    /// two must agree, or the summary a person reads is about a different run from the
    /// rows underneath it.
    @Test("adds up to what the run said", .tags(.integration))
    func addsUp() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let outcome = try await RunIntegrationTests.run(fixture)
        let report = RunReport(of: outcome)

        #expect(report.summary.killed == report.mutants.count { $0.outcome == "killed" })
        #expect(report.summary.survived == report.mutants.count { $0.outcome == "survived" })
        #expect(report.summary.rejected == report.rejected.count)
        #expect(report.filesInstrumented > 0)
    }

    /// Written, read back, and still the same run. A report nobody can parse is a report
    /// nobody has.
    @Test("survives being written and read again", .tags(.integration))
    func roundTrips() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let report = RunReport(of: try await RunIntegrationTests.run(fixture))
        let data = try RunReport.encoded(report)
        let again = try JSONDecoder().decode(RunReport.self, from: data)

        #expect(again == report)
        #expect(try RunReport.encoded(again) == data)
    }
}
