// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsSchemas
import Testing

@testable import SwiftMutantsReport

/// The account a run gives of itself, as a value.
///
/// Everything else is a projection of this: the summary a person reads, the Stryker file an
/// ecosystem reads, the cache that decides what a later run can skip, the exit code. So it
/// is the one artefact that has to be complete, stable and honest about what it does not
/// know - and the only one whose shape is a promise to anybody outside this repository.
@Suite("Run report")
struct RunReportTests {

    static func report(
        results: [MutantResult] = [],
        summary: RunSummary? = nil,
        scope: RunScope = .everything,
        positions: [WorkspaceRelativePath: LineIndex] = Fixture.positions
    ) -> RunReport {
        RunReport(
            of: Fixture.outcome(results: results, summary: summary, scope: scope),
            positions: positions
        )
    }

    /// Two rather than one since the report began carrying what a project's expectations
    /// amounted to. A reader of the older shape would find a key it does not know about,
    /// and one written by the older tool is missing a key this one requires - so the number
    /// moves rather than the field being made optional and quietly absent.
    @Test("says which shape it is")
    func saysItsShape() {
        let report = Self.report()
        #expect(report.schemaVersion == 2)
        #expect(report.tool.name == "swift-mutants")
        #expect(report.tool.version == Version.current)
    }

    /// Every column, every time, including the zeroes. A column that vanished when it was
    /// zero would make two runs of the same package produce different shapes, and anything
    /// reading the file would have to guess whether a missing key meant none or meant this
    /// version does not report it.
    @Test("carries every outcome column even at zero")
    func everyColumn() throws {
        let json = try Self.object(of: Self.report())
        let summary = try #require(json["summary"] as? [String: Any])
        for column in [
            "killed", "survived", "timedOut", "inconclusive", "errored", "notRun",
            "rejected", "equivalent", "uncovered", "cached", "expectedSurvivors",
        ] {
            #expect(summary[column] as? Int == 0, "missing \(column)")
        }
    }

    /// A run that measured nothing scores nothing. Zero would read as "caught none" and one
    /// as "caught all"; both are claims about tests that never ran.
    @Test("scores nothing rather than zero when there was nothing to score")
    func noScoreWithoutMutants() throws {
        let json = try Self.object(of: Self.report())
        let summary = try #require(json["summary"] as? [String: Any])
        #expect(summary["score"] is NSNull)
        #expect(summary["scoreOfCoveredCode"] is NSNull)
    }

    @Test("scores what it measured")
    func scoresWhatItMeasured() throws {
        let report = Self.report(summary: Fixture.counts(killed: 3, survived: 1, uncovered: 1))
        let json = try Self.object(of: report)
        let summary = try #require(json["summary"] as? [String: Any])
        #expect(summary["score"] as? Double == 0.75)
        #expect(summary["scoreOfCoveredCode"] as? Double == 1)
    }

    /// The whole identity, not the twenty characters a terminal shows. A report is read by
    /// programs, and two mutants whose short forms happen to agree are two mutants.
    @Test("names each mutant in full")
    func namesMutantsInFull() throws {
        let result = Fixture.result(.survived, tests: [])
        let json = try Self.object(of: Self.report(results: [result]))
        let mutants = try #require(json["mutants"] as? [[String: Any]])
        #expect(mutants.first?["id"] as? String == result.identity.digest.hexadecimal)
        #expect((mutants.first?["id"] as? String)?.count == 64)
    }

    /// A report names places inside somebody's repository, not inside the copy this ran in.
    /// An absolute path would be about a directory that no longer exists by the time anyone
    /// reads it.
    @Test("names places the way the repository does")
    func namesPlacesRelatively() throws {
        let json = try Self.object(of: Self.report(results: [Fixture.result(.survived, tests: [])]))
        let mutants = try #require(json["mutants"] as? [[String: Any]])
        #expect(mutants.first?["path"] as? String == "Sources/Codec/Header.swift")
    }

    /// Where a person looks, and where a program looks, are different numbers about the
    /// same thing. Both are carried, because deriving one from the other needs the file.
    @Test("says where a mutant is in both the words people use and the bytes it read")
    func saysWhereInBothCurrencies() throws {
        let json = try Self.object(of: Self.report(results: [Fixture.result(.survived, tests: [])]))
        let mutant = try #require((json["mutants"] as? [[String: Any]])?.first)
        #expect(mutant["line"] as? Int == 2)
        #expect(mutant["column"] as? Int == 3)
        let span = try #require(mutant["span"] as? [String: Any])
        #expect(span["start"] as? Int == 10)
        #expect(span["end"] as? Int == 11)
    }

    /// A file the run has no line index for still gets an entry. Losing a mutant because
    /// its position could not be worked out would be losing a finding to a formatting
    /// detail.
    @Test("still reports a mutant whose position it could not work out")
    func reportsAMutantWithoutAPosition() throws {
        let json = try Self.object(
            of: Self.report(
                results: [Fixture.result(.survived, tests: [])], positions: [:]))
        let mutant = try #require((json["mutants"] as? [[String: Any]])?.first)
        #expect(mutant["line"] is NSNull)
        #expect(mutant["column"] is NSNull)
        #expect((mutant["span"] as? [String: Any])?["start"] as? Int == 10)
    }

    /// A report that named a rule and a position would send a reader back to the file to
    /// work out what `lt-to-le@1` did to line 42, and the file may have moved on by then.
    @Test("says what each mutant changed, and to what")
    func saysWhatItChanged() throws {
        let json = try Self.object(of: Self.report(results: [Fixture.result(.survived, tests: [])]))
        let mutant = try #require((json["mutants"] as? [[String: Any]])?.first)
        #expect(mutant["original"] as? String == "<")
        #expect(mutant["replacement"] as? String == "<=")
    }

    /// The names a survivor's explanation needs, written once and pointed at. Twenty-four
    /// thousand copies of four hundred strings is not a report, it is a transcript.
    @Test("writes each test's name once and points at it")
    func namesTestsOnce() throws {
        let json = try Self.object(
            of: Self.report(results: [
                Fixture.result(.survived, tests: ["P.S/a()", "P.S/b()"]),
                Fixture.result(.killed, tests: ["P.S/a()"]),
            ]))
        #expect(json["tests"] as? [String] == ["P.S/a()", "P.S/b()"])
        let mutants = try #require(json["mutants"] as? [[String: Any]])
        #expect(mutants.first?["ran"] as? [Int] == [0, 1])
        #expect(mutants.last?["ran"] as? [Int] == [0])
    }

    @Test("says what became of each mutant, and what noticed it")
    func saysWhatBecameOfThem() throws {
        let json = try Self.object(
            of: Self.report(results: [
                Fixture.result(.killed, tests: ["P.S/a()", "P.S/b()"]),
                Fixture.result(.survived, tests: []),
            ]))
        let mutants = try #require(json["mutants"] as? [[String: Any]])
        #expect(mutants.map { $0["outcome"] as? String } == ["killed", "survived"])
        #expect(mutants.first?["killedBy"] as? [String] == ["P.S/a()", "P.S/b()"])
        // Present and empty, not absent: nothing noticed it, and the report says so.
        #expect(mutants.last?["killedBy"] is [String])
        #expect((mutants.last?["killedBy"] as? [String])?.isEmpty == true)
    }

    /// The run's own account of the ground it measured against.
    @Test("says how the tree behaved with nothing awake")
    func saysHowTheBaselineWent() throws {
        let json = try Self.object(of: Self.report())
        let baseline = try #require(json["baseline"] as? [String: Any])
        #expect(baseline["outcome"] as? String == "survived")
        #expect(json["contendedBaseline"] != nil)
        #expect(json["filesInstrumented"] as? Int == 1)
    }

    /// A scoped run's score is a score about the scope. Saying so is not a caveat, it is
    /// the number's meaning.
    @Test("says what it was asked to measure")
    func saysItsScope() throws {
        #expect(
            try #require(Self.object(of: Self.report())["scope"] as? [String: Any])["kind"]
                as? String == "everything"
        )
        let narrowed = Self.report(scope: .changed(since: "main", files: 4))
        let scope = try #require(try Self.object(of: narrowed)["scope"] as? [String: Any])
        #expect(scope["kind"] as? String == "changed")
        #expect(scope["since"] as? String == "main")
        #expect(scope["files"] as? Int == 4)
    }
}

extension RunReportTests {

    /// The report as JSON, read back as a dictionary.
    static func object(of report: RunReport) throws -> [String: Any] {
        let data = try RunReport.encoded(report)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Two runs of the same package must produce the same bytes.
///
/// A report that reordered its keys between runs could not be diffed, could not be
/// checksummed, and would show up as a change in every pull request that ran it twice.
@Suite("A report is the same twice")
struct ReportDeterminismTests {

    @Test("encodes to the same bytes every time")
    func sameBytes() throws {
        let results = [
            RunReportTests.Fixture.result(.killed, tests: ["P.S/a()"]),
            RunReportTests.Fixture.result(.survived, tests: []),
        ]
        let first = try RunReport.encoded(RunReportTests.report(results: results))
        let second = try RunReport.encoded(RunReportTests.report(results: results))
        #expect(first == second)
    }

    /// Sorted, so that the bytes do not depend on the order a dictionary happened to
    /// enumerate in - which Swift deliberately varies between processes.
    @Test("puts its keys in one order")
    func sortedKeys() throws {
        let text = String(
            decoding: try RunReport.encoded(RunReportTests.report()), as: UTF8.self)
        let keys = ["baseline", "contendedBaseline", "filesInstrumented", "mutants"]
        let places = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(places.count == keys.count)
        #expect(places == places.sorted())
    }

    /// A path is not a URL. Escaping its slashes would make every path in the file harder
    /// to read for no gain.
    @Test("leaves the slashes in a path alone")
    func unescapedSlashes() throws {
        let text = String(
            decoding: try RunReport.encoded(
                RunReportTests.report(results: [RunReportTests.Fixture.result(.survived, tests: [])]
                )
            ), as: UTF8.self)
        #expect(text.contains("Sources/Codec/Header.swift"))
        #expect(!text.contains("Sources\\/Codec"))
    }

    /// Written for a person as well as a program: a run's report is something people read
    /// in a pull request.
    @Test("is written to be read")
    func prettyPrinted() throws {
        let text = String(
            decoding: try RunReport.encoded(RunReportTests.report()), as: UTF8.self)
        #expect(text.contains("\n"))
    }
}

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
