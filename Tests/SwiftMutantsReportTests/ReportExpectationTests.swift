// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import Testing

@testable import SwiftMutantsReport

/// What a report says about the survivors a project wrote down.
///
/// In the report and not only on stdout, because the report is what a build reads. A CI job
/// that had to parse a summary line to find out which expectation went wrong would be a job
/// that breaks the next time a sentence is reworded.
@Suite("Expectations in a report")
struct ReportExpectationTests {

    static let identity = String(repeating: "a", count: 64)

    static func expectation(_ reason: String = "unreachable") -> Configuration.Expectation {
        Configuration.Expectation(identity: Self.identity, reason: reason)
    }

    /// One verdict, spelled once. Every test here is about one of its four fields, and
    /// naming the other three at each call site would bury which one it is about.
    static func verdict(
        met: Int = 0,
        contradicted: [Expectations.Contradiction] = [],
        stale: [Configuration.Expectation] = [],
        superseded: [Configuration.Expectation] = []
    ) -> Expectations.Verdict {
        Expectations.Verdict(
            met: met, contradicted: contradicted, stale: stale, superseded: superseded)
    }

    static func report(_ verdict: Expectations.Verdict) -> RunReport {
        RunReport(of: RunReportTests.Fixture.outcome(results: [], expectations: verdict))
    }

    @Test("carries how many were met")
    func carriesMet() {
        let report = Self.report(Self.verdict(met: 2))
        #expect(report.expectations.met == 2)
        #expect(report.expectations.contradicted.isEmpty)
    }

    /// The identity and the reason both, because the fix is an edit to that exact line of
    /// their configuration and the reason is how they recognise it.
    @Test("names each expectation the run disagreed with")
    func carriesContradictions() throws {
        let report = Self.report(
            Self.verdict(
                contradicted: [
                    Expectations.Contradiction(
                        expectation: Self.expectation("guarded by the caller"),
                        reason: "this was caught"
                    )
                ]
            )
        )
        let row = try #require(report.expectations.contradicted.first)
        #expect(row.identity == Self.identity)
        #expect(row.reason == "guarded by the caller")
        #expect(row.disagreement.value == "this was caught")
    }

    @Test("names each expectation whose mutant is gone")
    func carriesStale() throws {
        let report = Self.report(Self.verdict(stale: [Self.expectation("was unreachable")]))
        let row = try #require(report.expectations.stale.first)
        #expect(row.identity == Self.identity)
        #expect(row.reason == "was unreachable")
    }

    @Test("says whether anything in the configuration is wrong")
    func carriesSatisfaction() {
        #expect(
            Self.report(
                Expectations.Verdict(met: 1, contradicted: [], stale: [], superseded: [])
            )
            .expectations.isSatisfied)
        #expect(
            !Self.report(
                Expectations.Verdict(
                    met: 0, contradicted: [], stale: [Self.expectation()], superseded: [])
            )
            .expectations.isSatisfied)
    }

    /// Every key every time, zeroes included - the report's first rule. A block that
    /// vanished when a project had no expectations would leave a reader unable to tell
    /// "none" from "this version does not say".
    @Test("says so even when the project expected nothing")
    func presentWhenEmpty() throws {
        let encoded = try RunReport.encoded(Self.report(.unasked))
        let document = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let block = try #require(document["expectations"] as? [String: Any])
        #expect(block["met"] as? Int == 0)
        #expect((block["contradicted"] as? [Any])?.isEmpty == true)
    }

    /// A report from a version that did not carry them is not a report with none.
    @Test("refuses a document that does not say")
    func refusesADocumentWithout() throws {
        let encoded = try RunReport.encoded(Self.report(.unasked))
        var document = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        document.removeValue(forKey: "expectations")
        let without = try JSONSerialization.data(withJSONObject: document)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RunReport.self, from: without)
        }
    }
}

/// What a report says about tests that did not run in the copy.
///
/// The narration says it once and scrolls away; the report is what a gate, an audit and
/// anybody reading a survivor list a week later has. A mutant only a skipped test covers
/// reports as surviving however good that test is, so the reason has to be in the same
/// document as the list it explains.
@Suite("A report carries what stepped aside")
struct ReportedSkipsTests {

    static func baseline(skipping tests: [String]) -> RunReport {
        let outcome = RunReportTests.Fixture.outcome(results: [])
        return RunReport(
            of: RunOutcome(
                results: outcome.results,
                rejected: outcome.rejected,
                summary: outcome.summary,
                baseline: Verdict(
                    outcome: .survived,
                    killedBy: [],
                    firstFailure: nil,
                    startedTests: ["P.S/a()"],
                    durationMilliseconds: 231,
                    skippedTests: tests,
                    termination: .exited(0)
                ),
                contendedBaseline: outcome.contendedBaseline,
                filesInstrumented: outcome.filesInstrumented,
                scope: outcome.scope,
                positions: outcome.positions,
                digests: outcome.digests,
                expectations: outcome.expectations
            )
        )
    }

    @Test("names them in the baseline it reports")
    func namesThem() {
        let report = Self.baseline(skipping: ["P.NeedsRepository/alphabet()"])
        #expect(report.baseline.testsSkipped == ["P.NeedsRepository/alphabet()"])
    }

    @Test("says nothing about skips when none happened")
    func saysNothing() {
        #expect(Self.baseline(skipping: []).baseline.testsSkipped.isEmpty)
    }

    /// A report written before this answer existed is a report about a run that happened,
    /// not a report that cannot be read. `ReportStore.read` answers what it cannot decode
    /// with `nil`, and every caller reads that as "nobody has run this yet" - so a required
    /// key would turn every earlier report into a run that never was, silently.
    @Test("reads a report written before this answer existed")
    func readsAnOlderReport() throws {
        let older = """
            {"outcome":"survived","testsStarted":3,"durationMilliseconds":231}
            """
        let read = try JSONDecoder().decode(
            RunReport.Behaviour.self, from: Data(older.utf8))
        #expect(read.testsSkipped.isEmpty)
        #expect(read.testsStarted == 3)
    }
}
