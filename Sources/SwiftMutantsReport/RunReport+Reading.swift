// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import SwiftMutantsConfig
public import SwiftMutantsSchemas
public import SwiftMutantsCore
public import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsValidate

extension RunReport {

    /// Reads a finished run.
    ///
    /// `positions` says where each byte offset falls in the file a person reads. A file it
    /// has nothing for still yields entries, with `null` for line and column: losing a
    /// finding because its position could not be worked out would be losing it to a
    /// formatting detail.
    public init(
        of outcome: RunOutcome,
        positions override: [WorkspaceRelativePath: LineIndex]? = nil,
        version: String = Version.current
    ) {
        let positions = override ?? outcome.positions
        self.schemaVersion = 2
        self.tool = Tool(name: "swift-mutants", version: version)
        self.scope = Scope(of: outcome.scope, shard: outcome.shard?.description)
        self.summary = Summary(of: outcome.summary)
        self.baseline = Behaviour(of: outcome.baseline)
        self.contendedBaseline = Behaviour(of: outcome.contendedBaseline)
        self.filesInstrumented = outcome.filesInstrumented

        self.files = Dictionary(
            uniqueKeysWithValues: outcome.digests.map { ($0.key.rendered, $0.value.hexadecimal) })
        let named = Self.naming(outcome.results)
        let seen = named.positions
        self.tests = named.names

        self.mutants = outcome.results.map { result in
            let place = positions[result.path]?.position(of: result.span.start)
            return Mutant(
                id: result.identity.digest.hexadecimal,
                path: result.path.rendered,
                line: Reported(place?.line),
                column: Reported(place?.column),
                span: Span(start: result.span.start, end: result.span.end),
                rule: result.rule.rendered,
                original: result.original,
                replacement: result.replacement,
                outcome: result.verdict.outcome.rawValue,
                killedBy: result.verdict.killedBy,
                ran: result.verdict.startedTests.compactMap { seen[$0] },
                testsStarted: result.verdict.testsStarted,
                attempts: result.attempts,
                durationMilliseconds: result.verdict.durationMilliseconds
            )
        }
        self.rejected = outcome.rejected.map { refusal in
            Refusal(
                id: refusal.identity.digest.hexadecimal,
                rule: refusal.rule.rendered,
                span: Span(start: refusal.span.start, end: refusal.span.end),
                diagnostics: refusal.diagnostics.map {
                    Diagnostic(
                        file: $0.file,
                        line: $0.position.line,
                        column: $0.position.column,
                        severity: $0.severity.rawValue,
                        message: $0.message
                    )
                }
            )
        }
        self.expectations = Expectations(of: outcome.expectations)
    }

    /// Every test any mutant started, written once, with where each one is.
    ///
    /// In the order the run started them, so two runs of the same package produce the same
    /// list. The names repeat across mutants - a package with six hundred mutants facing
    /// forty tests each would carry twenty-four thousand copies of four hundred strings -
    /// so they are written once and pointed at.
    private static func naming(
        _ results: [MutantResult]
    ) -> (names: [String], positions: [String: Int]) {
        var positions: [String: Int] = [:]
        var names: [String] = []
        for result in results {
            for test in result.verdict.startedTests where positions[test] == nil {
                positions[test] = names.count
                names.append(test)
            }
        }
        return (names, positions)
    }

    /// The report as bytes, the same bytes every time - and only if it kept its promise.
    ///
    /// Sorted keys, because Swift deliberately varies the order a dictionary enumerates in
    /// between processes and a report that reordered itself could not be diffed or
    /// checksummed. Unescaped slashes, because a path is not a URL. Indented, because
    /// people read these in pull requests.
    ///
    /// Checked here because this is the one place a report turns into bytes: the history
    /// store, `--json` on stdout, and anything added later all pass through it, so a caller
    /// cannot forget. Checking afterwards would be checking what somebody has already read.
    ///
    /// - Throws: ``Schemas/Invalid`` naming everything wrong, rather than writing a document
    ///   whose shape this tool has promised and does not have.
    public static func encoded(
        _ report: Self, checkedAgainst schema: JSONSchema = Schemas.schema(Schemas.runReport)
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        let bytes = try encoder.encode(report)
        let violations = schema.validate(bytes)
        guard violations.isEmpty else {
            throw Schemas.Invalid(schema: Schemas.runReport, violations: violations)
        }
        return bytes
    }
}

extension RunReport.Scope {
    init(of scope: RunScope, shard: String?) {
        switch scope {
        case .everything:
            self.init(
                kind: "everything", since: .init(nil), files: .init(nil), shard: .init(shard))
        case .changed(let reference, let files):
            self.init(
                kind: "changed",
                since: .init(reference),
                files: .init(files),
                shard: .init(shard)
            )
        }
    }
}

extension RunReport.Summary {
    init(of summary: RunSummary) {
        self.init(
            killed: summary.killed,
            survived: summary.survived,
            timedOut: summary.timedOut,
            inconclusive: summary.inconclusive,
            errored: summary.errored,
            notRun: summary.notRun,
            rejected: summary.rejected,
            equivalent: summary.equivalent,
            uncovered: summary.uncovered,
            cached: summary.cached,
            expectedSurvivors: summary.expectedSurvivors,
            score: .init(summary.score.value),
            scoreOfCoveredCode: .init(summary.score.ofCoveredCode)
        )
    }
}

extension RunReport.Expectations {
    init(of verdict: SwiftMutantsEngine.Expectations.Verdict) {
        self.init(
            met: verdict.met,
            contradicted: verdict.contradicted.map {
                RunReport.ExpectationRow(
                    identity: $0.expectation.identity,
                    reason: $0.expectation.reason,
                    disagreement: $0.reason
                )
            },
            stale: verdict.stale.map {
                RunReport.ExpectationRow(
                    identity: $0.identity, reason: $0.reason, disagreement: nil)
            },
            superseded: verdict.superseded.map {
                RunReport.ExpectationRow(
                    identity: $0.identity, reason: $0.reason, disagreement: nil)
            },
            isSatisfied: verdict.isSatisfied
        )
    }
}

extension RunReport.Behaviour {
    init(of verdict: Verdict) {
        self.init(
            outcome: verdict.outcome.rawValue,
            testsStarted: verdict.testsStarted,
            durationMilliseconds: verdict.durationMilliseconds
        )
    }
}
