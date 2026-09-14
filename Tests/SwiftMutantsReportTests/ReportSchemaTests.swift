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

/// The report the tool writes has the shape the tool promises.
///
/// Two things, and only together are they worth anything. Every document this makes has to
/// validate - otherwise the schema is decoration. And every key the encoder emits has to be
/// declared by the schema - otherwise somebody adds a field, nothing complains, and the
/// published shape quietly stops describing the document.
///
/// The second half is what `additionalProperties: false` buys: a key nobody declared is a
/// violation, so adding a field to the type without adding it to the schema fails here.
@Suite("A report keeps the shape it promises")
struct ReportSchemaConformanceTests {

    /// A report with something in every list, so the parts that only appear when a run
    /// found something are checked too. A fixture of an empty run would validate against a
    /// schema that described nothing.
    static var populated: RunReport {
        RunReport(
            of: RunReportTests.Fixture.outcome(
                results: [
                    RunReportTests.Fixture.result(.killed, tests: ["P.S/a()"]),
                    RunReportTests.Fixture.result(.survived, tests: []),
                ],
                scope: .changed(since: "HEAD", files: 2),
                expectations: Expectations.Verdict(
                    met: 1,
                    contradicted: [
                        Expectations.Contradiction(
                            expectation: Configuration.Expectation(
                                identity: String(repeating: "a", count: 64), reason: "caught"),
                            reason: "this was caught"
                        )
                    ],
                    stale: [
                        Configuration.Expectation(
                            identity: String(repeating: "b", count: 64), reason: "gone")
                    ],
                    superseded: [
                        Configuration.Expectation(
                            identity: String(repeating: "c", count: 64), reason: "equivalent")
                    ]
                ),
                rejected: [RunReportTests.Fixture.refusal()]
            ))
    }

    @Test("validates against the schema shipped with it")
    func validates() throws {
        let violations = Schemas.schema(Schemas.runReport)
            .validate(try RunReport.encoded(Self.populated))
        #expect(violations.isEmpty, "\(violations.map(\.description).joined(separator: "\n"))")
    }

    /// An empty run is a different document - no mutants, no tests, nothing refused, both
    /// scores null - and it has to validate too. `null` where a schema says `number` is
    /// exactly the drift this catches.
    @Test("validates when the run found nothing")
    func validatesAnEmptyRun() throws {
        let report = RunReport(of: RunReportTests.Fixture.outcome(results: []))
        let violations = Schemas.schema(Schemas.runReport).validate(try RunReport.encoded(report))
        #expect(violations.isEmpty, "\(violations.map(\.description).joined(separator: "\n"))")
    }

    /// The other direction, made concrete: a key the schema does not declare is refused, so
    /// a field added to the type and not to the schema fails the two tests above.
    @Test("refuses a key the schema does not declare")
    func refusesAnUndeclaredKey() throws {
        var document = try #require(
            try JSONSerialization.jsonObject(with: try RunReport.encoded(Self.populated))
                as? [String: Any])
        document["somethingNew"] = 1
        let violations = Schemas.schema(Schemas.runReport)
            .validate(try JSONSerialization.data(withJSONObject: document))
        #expect(violations.count == 1)
        #expect(violations.first?.message.contains("somethingNew") == true)
    }

    /// And a key the schema requires that the document does not have.
    @Test("refuses a document missing something it promised")
    func refusesAMissingKey() throws {
        var document = try #require(
            try JSONSerialization.jsonObject(with: try RunReport.encoded(Self.populated))
                as? [String: Any])
        document.removeValue(forKey: "summary")
        let violations = Schemas.schema(Schemas.runReport)
            .validate(try JSONSerialization.data(withJSONObject: document))
        #expect(violations.count == 1)
        #expect(violations.first?.message.contains("summary") == true)
    }
}

/// No report reaches a file or a pipe without being checked first.
///
/// At the one place every report turns into bytes, so a caller cannot forget: writing to the
/// history store, writing `--json` to stdout, and anything added later all pass through it.
/// Checking afterwards would be checking what somebody has already read.
///
/// What this adds over the conformance tests is the shapes no fixture thought of. Those fix
/// that the schema and the type agree about the cases somebody wrote down; this catches a
/// document that drifts on a case nobody did, on somebody's machine, before it is written.
@Suite("Nothing is written unchecked")
struct ReportWriteGateTests {

    @Test("hands back the bytes when the report keeps its promise")
    func writesAValidReport() throws {
        #expect(throws: Never.self) {
            try RunReport.encoded(ReportSchemaConformanceTests.populated)
        }
    }

    /// A schema the report does not satisfy, which is the nearest thing to a report whose
    /// shape has drifted that can be constructed deliberately.
    static var demanding: JSONSchema {
        guard
            let schema = try? JSONSchema(
                Data(
                    #"""
                    {"type": "object",
                     "required": ["schemaVersion", "nobodyWritesThis", "norThis"],
                     "properties": {"schemaVersion": {"type": "string"}}}
                    """#.utf8))
        else { fatalError("malformed fixture schema") }
        return schema
    }

    /// Held to a promise it does not keep, it refuses rather than writing.
    @Test("refuses rather than writing a document that broke its promise")
    func refusesAnInvalidReport() throws {
        #expect(throws: Schemas.Invalid.self) {
            try RunReport.encoded(
                ReportSchemaConformanceTests.populated, checkedAgainst: Self.demanding)
        }
    }

    /// And says everything wrong with it, not the first thing. Somebody diagnosing this is
    /// reading a defect report about swift-mutants, and one line per run is one run per line.
    @Test("says everything wrong with it")
    func saysEverything() throws {
        do {
            _ = try RunReport.encoded(
                ReportSchemaConformanceTests.populated, checkedAgainst: Self.demanding)
            Issue.record("a report that broke its promise was written")
        } catch let invalid as Schemas.Invalid {
            #expect(invalid.violations.count == 3)
            #expect(invalid.description.contains("defect in swift-mutants"))
        }
    }

    /// And the default is the run report's own schema, not nothing. A gate whose default
    /// checked against an empty schema would be a gate that passed everything, so this
    /// hands it a report that is wrong in the one way the type still permits.
    @Test("checks against the run report's own schema unless told otherwise")
    func defaultsToItsOwnSchema() throws {
        #expect(Schemas.runReport == "run-report-v2.schema.json")
        let report = ReportSchemaConformanceTests.populated
        let misdeclared = RunReport(
            schemaVersion: report.schemaVersion + 1,
            tool: report.tool,
            scope: report.scope,
            summary: report.summary,
            baseline: report.baseline,
            contendedBaseline: report.contendedBaseline,
            filesInstrumented: report.filesInstrumented,
            files: report.files,
            tests: report.tests,
            mutants: report.mutants,
            rejected: report.rejected,
            expectations: report.expectations,
            invocation: report.invocation
        )
        #expect(throws: Schemas.Invalid.self) { try RunReport.encoded(misdeclared) }
    }
}

/// The projections keep the shapes they promise too.
///
/// Each of these is a one-way, lossy view of the canonical report, written for somebody
/// else's reader. That is exactly why they need a gate: nobody in this repository reads
/// them, so a field that drifted would be found by a stranger's dashboard rather than by a
/// test - and what they would see is a document that does not load, with no clue whose
/// fault it is.
///
/// The schemas are of this tool's own subset rather than copies of the ecosystem ones, and
/// each says so in its description. A gate on our drift is a thing this repository can
/// keep; a conformance check on Stryker's shape is Stryker's to keep.
@Suite("The projections keep their promises")
struct ProjectionSchemaTests {

    static let sources = ["Sources/Codec/Header.swift": "let a=1\nab< b\n"]

    /// Every outcome, so every branch of the status mapping is written at least once - a
    /// fixture of one survivor would leave seven of the eight unchecked.
    static var report: RunReport {
        RunReport(
            of: RunReportTests.Fixture.outcome(
                results: Outcome.allCases.map {
                    RunReportTests.Fixture.result($0, tests: $0 == .killed ? ["P.S/a()"] : [])
                },
                rejected: [RunReportTests.Fixture.refusal()]
            ))
    }

    @Test("the Stryker projection validates against the schema shipped with it")
    func strykerValidates() throws {
        #expect(throws: Never.self) {
            try StrykerReport.encoded(
                StrykerReport(of: Self.report, sources: Self.sources))
        }
    }

    @Test("the SARIF projection validates against the schema shipped with it")
    func sarifValidates() throws {
        #expect(throws: Never.self) {
            try SarifReport.encoded(SarifReport(of: Self.report))
        }
    }

    /// And each refuses rather than writing, when held to a promise it does not keep.
    @Test("neither is written when it would not keep its promise")
    func neitherIsWrittenWrong() throws {
        #expect(throws: Schemas.Invalid.self) {
            try StrykerReport.encoded(
                StrykerReport(of: Self.report, sources: Self.sources),
                checkedAgainst: Schemas.sarifProjection)
        }
        #expect(throws: Schemas.Invalid.self) {
            try SarifReport.encoded(
                SarifReport(of: Self.report), checkedAgainst: Schemas.strykerProjection)
        }
    }
}
