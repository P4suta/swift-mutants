// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner

extension RunReportTests {

    /// The pieces a report test needs, built once and named.
    ///
    /// `RuleIdentifier`, `SourceSpan` and `WorkspaceRelativePath` all refuse malformed
    /// input, which is right for a library and noisy in a fixture. Refusing here is a bug
    /// in the fixture rather than a fact about the code under test.
    enum Fixture {

        static let path: WorkspaceRelativePath = build("Sources/Codec/Header.swift")
        static let rule: RuleIdentifier = build("lt-to-le@1")
        static let span: SourceSpan = build(start: 10, end: 11)

        /// A file whose byte 10 is on line 2, column 3 - the `<` this mutant is about.
        static let positions: [WorkspaceRelativePath: LineIndex] = [
            path: LineIndex("let a=1\nab< b\n")
        ]

        private static func build(_ spelling: String) -> WorkspaceRelativePath {
            guard let path = WorkspaceRelativePath(spelling) else {
                fatalError("malformed fixture path")
            }
            return path
        }

        private static func build(_ spelling: String) -> RuleIdentifier {
            guard let rule = RuleIdentifier(spelling) else {
                fatalError("malformed fixture rule")
            }
            return rule
        }

        private static func build(start: Int, end: Int) -> SourceSpan {
            guard let span = SourceSpan(start: start, end: end) else {
                fatalError("malformed fixture span")
            }
            return span
        }

        static func verdict(_ outcome: Outcome, tests: [String]) -> Verdict {
            Verdict(
                outcome: outcome,
                killedBy: outcome == .killed ? tests : [],
                firstFailure: outcome == .killed ? tests.first : nil,
                startedTests: tests,
                durationMilliseconds: 231,
                termination: .exited(0)
            )
        }

        static func result(_ outcome: Outcome, tests: [String]) -> MutantResult {
            MutantResult(
                identity: MutantIdentity(
                    MutantIdentity.Inputs(
                        path: path,
                        enclosingDeclaration: "s:7Example1fyySiF",
                        rule: rule,
                        span: span,
                        sourceDigest: Digest.of("a < b"),
                        originalBytes: Digest.of("<"),
                        replacementBytes: Digest.of("<=")
                    )
                ),
                path: path,
                rule: rule,
                span: span,
                original: "<",
                replacement: "<=",
                verdict: verdict(outcome, tests: tests),
                attempts: 1
            )
        }

        static func counts(killed: Int, survived: Int, uncovered: Int) -> RunSummary {
            guard
                let counts = RunSummary(
                    killed: killed,
                    survived: survived,
                    timedOut: 0,
                    inconclusive: 0,
                    errored: 0,
                    notRun: 0,
                    rejected: 0,
                    equivalent: 0,
                    uncovered: uncovered,
                    cached: 0,
                    expectedSurvivors: 0
                )
            else {
                fatalError("malformed fixture tally")
            }
            return counts
        }

        static func outcome(
            results: [MutantResult], summary: RunSummary?, scope: RunScope
        ) -> RunOutcome {
            let derived = counts(
                killed: results.count { $0.verdict.outcome == .killed },
                survived: results.count { $0.verdict.outcome == .survived },
                uncovered: results.count {
                    $0.verdict.outcome == .survived && $0.verdict.startedTests.isEmpty
                }
            )
            return RunOutcome(
                results: results,
                rejected: [],
                summary: summary ?? derived,
                baseline: verdict(.survived, tests: ["P.S/a()"]),
                contendedBaseline: verdict(.survived, tests: ["P.S/a()"]),
                filesInstrumented: 1,
                scope: scope
            )
        }
    }
}
