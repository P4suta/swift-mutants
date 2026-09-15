// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsValidate
import Testing

@testable import SwiftMutantsReport

/// Where a refused mutant's diagnostic says it is.
///
/// A run happens inside a disposable copy, so the compiler names files in it. That path is
/// gone by the time anybody reads the report, is different on every run - so two reports of
/// the same package cannot be diffed - and matches nothing a reader has open. Every other
/// path in this report is the one they wrote; this one was the odd exception.
@Suite("A refusal's paths")
struct RefusalPathTests {

    static func report(
        naming file: String, builtIn tree: String?
    ) -> RunReport {
        let refusal = Rejection(
            identity: RunReportTests.Fixture.result(.killed, tests: []).identity,
            rule: RunReportTests.Fixture.rule,
            span: RunReportTests.Fixture.span,
            diagnostics: [
                CompilerDiagnostic(
                    file: file,
                    position: SourcePosition(line: 2, column: 3),
                    severity: .error,
                    message: "binary operator '<=' cannot be applied to two 'Data' operands"
                )
            ]
        )
        let plans = tree.map {
            TestBundles(plans: [
                TestPlan(
                    executable: "/helper",
                    arguments: [],
                    environment: [:],
                    directory: $0,
                    module: "PTests"
                )
            ])
        }
        return RunReport(
            of: RunOutcome(
                results: [],
                rejected: [refusal],
                summary: RunReportTests.Fixture.counts(killed: 0, survived: 0, uncovered: 0),
                baseline: RunReportTests.Fixture.verdict(.survived, tests: ["P.S/a()"]),
                contendedBaseline: RunReportTests.Fixture.verdict(.survived, tests: ["P.S/a()"]),
                filesInstrumented: 1,
                scope: .everything,
                positions: RunReportTests.Fixture.positions,
                digests: RunReportTests.Fixture.digests,
                expectations: .unasked,
                bundles: plans
            ),
            version: "0.0.0-test"
        )
    }

    @Test("says where a refused mutant is in the tree the reader wrote")
    func relativeToTheWorkspace() throws {
        let report = Self.report(
            naming: "/tmp/w-1234/tree/Sources/Codec/Header.swift", builtIn: "/tmp/w-1234/tree")
        let said = try #require(report.rejected.first?.diagnostics.first?.file)
        #expect(said == "Sources/Codec/Header.swift")
    }

    /// A diagnostic about a dependency or an SDK header is not the reader's file, and
    /// shortening it would be dressing it up as one.
    @Test("leaves a file outside the copy exactly as the compiler named it")
    func outsideTheCopy() throws {
        let outside = "/Library/Developer/CommandLineTools/usr/include/stdio.h"
        let report = Self.report(naming: outside, builtIn: "/tmp/w-1234/tree")
        #expect(report.rejected.first?.diagnostics.first?.file == outside)
    }

    /// A run that never got as far as building has no copy to be relative to, and the
    /// compiler's own words are still the best thing to show.
    @Test("leaves the path alone when there was no copy")
    func withoutATree() throws {
        let named = "/tmp/w-1234/tree/Sources/Codec/Header.swift"
        let report = Self.report(naming: named, builtIn: nil)
        #expect(report.rejected.first?.diagnostics.first?.file == named)
    }
}
