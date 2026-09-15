// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import SwiftMutantsBuild
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
    /// `kept` says whether the copy the run happened in is still there. A run works inside
    /// a disposable snapshot, so it usually is not - and a command naming a directory that
    /// no longer exists is a command somebody pastes and then has to work out why it failed.
    public init(
        of outcome: RunOutcome,
        positions override: [WorkspaceRelativePath: LineIndex]? = nil,
        version: String = Version.current,
        kept: Bool = false
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

        self.mutants = outcome.results.map { Self.row(of: $0, at: positions, naming: seen) }
        // The compiler named files inside the disposable copy. By the time anybody reads
        // this the copy is gone, its path was different last run and will be different
        // next, and nothing in it matches a file the reader has open.
        let tree = outcome.bundles?.plans.first?.directory
        self.rejected = outcome.rejected.map { Self.refusal($0, under: tree) }
        self.expectations = Expectations(of: outcome.expectations)
        self.invocation = Invocation(of: outcome.bundles, kept: kept)
    }

    /// One mutant's row, with where it is in the file a person reads.
    private static func row(
        of result: MutantResult,
        at positions: [WorkspaceRelativePath: LineIndex],
        naming seen: [String: Int]
    ) -> Mutant {
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
            durationMilliseconds: result.verdict.durationMilliseconds,
            index: Int(result.index)
        )
    }

    /// One refusal's row, with the compiler's own words in it.
    private static func refusal(_ refusal: Rejection, under tree: String?) -> Refusal {
        Refusal(
            id: refusal.identity.digest.hexadecimal,
            rule: refusal.rule.rendered,
            span: Span(start: refusal.span.start, end: refusal.span.end),
            diagnostics: refusal.diagnostics.map {
                Diagnostic(
                    file: Self.inTheWorkspace($0.file, under: tree),
                    line: $0.position.line,
                    column: $0.position.column,
                    severity: $0.severity.rawValue,
                    message: $0.message
                )
            }
        )
    }

    /// A compiler's path, said the way the rest of the report says paths.
    ///
    /// A run happens inside a disposable copy, so the compiler names files in it. That
    /// path is gone by the time anybody reads the report, is different on every run - so
    /// two reports of the same package cannot be diffed - and matches nothing a reader has
    /// open. The same file relative to the copy's root is the path they wrote, which is
    /// the one every other part of this report uses.
    ///
    /// A file outside the copy is left exactly as it is. A diagnostic about a dependency
    /// or an SDK header is not the reader's file, and shortening it would be dressing it
    /// up as one.
    private static func inTheWorkspace(_ file: String, under tree: String?) -> String {
        guard let tree, !tree.isEmpty else { return file }
        let root = tree.hasSuffix("/") ? tree : tree + "/"
        guard file.hasPrefix(root) else { return file }
        return String(file.dropFirst(root.count))
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

extension RunReport.Invocation {

    /// What the run's own plan says, with nothing of the environment in it.
    ///
    /// A run that never got as far as building has no plan, and the empty strings say so
    /// rather than naming a bundle nobody built. `explain` prints nothing in that case,
    /// which is the truth: there is no command that would reproduce it.
    init(of bundles: TestBundles?, kept: Bool) {
        let plans = bundles?.plans ?? []
        self.init(
            bundles: plans.map {
                RunReport.LaunchedBundle(
                    module: $0.module, executable: $0.executable, arguments: $0.arguments)
            },
            // Shared across bundles, because one build settled them: the same copy, the
            // same event stream, the same variables this tool worked out.
            directory: plans.first?.directory ?? "",
            eventStreamVersion: plans.first?.eventStreamVersion ?? "",
            environment: plans.first?.derived ?? [:],
            kept: kept
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
