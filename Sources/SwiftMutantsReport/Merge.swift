// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Putting the shares of one run back together.
///
/// Five machines measure a fifth each and produce five reports, each holding every mutant
/// and an answer for a fifth of them. None of them is the answer: a person reading one
/// would read a score about a fifth of a package.
///
/// This is the arithmetic nobody should do by hand - every mutant once, with the answer
/// from whichever share measured it, and the counts recomputed from that rather than added
/// up from five summaries that each counted the others as `not-run`.
public enum Merge {

    /// One report out of several shares of the same run, or nothing if they are not that.
    ///
    /// Refused rather than approximated when the shares do not describe the same package:
    /// two reports about different code are not two shares of one run, and merging them
    /// would produce a score about a program nobody has.
    public static func of(_ shares: [RunReport]) -> RunReport? {
        guard let first = shares.first else { return nil }
        guard shares.allSatisfy({ $0.files == first.files }) else { return nil }

        // One list of test names for the merged report. A position in one share's list
        // means nothing in another's, so every reference is renumbered rather than copied.
        var position: [String: Int] = [:]
        var names: [String] = []
        for share in shares {
            for name in share.tests where position[name] == nil {
                position[name] = names.count
                names.append(name)
            }
        }

        var answered: [String: RunReport.Mutant] = [:]
        var order: [String] = []
        for share in shares {
            for mutant in share.mutants {
                if answered[mutant.id] == nil { order.append(mutant.id) }
                // A share that did not measure it is not a vote for `not-run`; it is a
                // share that was not asked. So anything already measured stands, and
                // anything not yet measured is replaced by whatever this share has - which
                // is either a real answer or the same absence.
                guard answered[mutant.id]?.outcome ?? "not-run" == "not-run" else { continue }
                answered[mutant.id] = Self.renumbered(mutant, from: share.tests, to: position)
            }
        }

        let mutants = order.compactMap { answered[$0] }
        return first.replacing(
            mutants: mutants,
            tests: names,
            shard: nil,
            summary: Self.counted(mutants, rejected: first.summary.rejected),
            expectations: Self.combined(shares.map(\.expectations))
        )
    }

    /// What every share together said about the project's expectations.
    ///
    /// Every share sees the whole catalogue - another machine's mutants come back as
    /// `not-run` rows - so staleness is the same finding in all of them and is said once.
    /// Which expectation was met or contradicted is only knowable by the share that
    /// measured it, so those are disjoint and add up.
    ///
    /// A contradiction one machine found is a contradiction of the whole run. Merging by
    /// letting a satisfied share win would turn five machines into a way to lose a finding.
    static func combined(_ shares: [RunReport.Expectations]) -> RunReport.Expectations {
        func once(_ rows: [RunReport.ExpectationRow]) -> [RunReport.ExpectationRow] {
            var seen: Set<String> = []
            return rows.filter { seen.insert($0.identity).inserted }
        }
        let contradicted = once(shares.flatMap(\.contradicted))
        let stale = once(shares.flatMap(\.stale))
        return RunReport.Expectations(
            met: shares.reduce(0) { $0 + $1.met },
            contradicted: contradicted,
            stale: stale,
            superseded: once(shares.flatMap(\.superseded)),
            isSatisfied: contradicted.isEmpty && stale.isEmpty
        )
    }

    /// One mutant with its test references pointing at the merged list.
    static func renumbered(
        _ mutant: RunReport.Mutant, from names: [String], to position: [String: Int]
    ) -> RunReport.Mutant {
        RunReport.Mutant(
            id: mutant.id,
            path: mutant.path,
            line: mutant.line,
            column: mutant.column,
            span: mutant.span,
            rule: mutant.rule,
            original: mutant.original,
            replacement: mutant.replacement,
            outcome: mutant.outcome,
            killedBy: mutant.killedBy,
            ran: mutant.ran.compactMap {
                names.indices.contains($0) ? position[names[$0]] : nil
            },
            testsStarted: mutant.testsStarted,
            attempts: mutant.attempts,
            durationMilliseconds: mutant.durationMilliseconds,
            index: mutant.index
        )
    }

    /// The counts of the merged answers.
    ///
    /// Recomputed rather than summed. Five summaries that each counted the others as
    /// `not-run` would add up to four fifths of the catalogue never having been measured.
    static func counted(_ mutants: [RunReport.Mutant], rejected: Int) -> RunReport.Summary {
        var counts: [String: Int] = [:]
        for mutant in mutants { counts[mutant.outcome, default: 0] += 1 }
        let uncovered = mutants.count { $0.outcome == "survived" && $0.testsStarted == 0 }

        let killed = counts["killed"] ?? 0
        let survived = counts["survived"] ?? 0
        let timedOut = counts["timed-out"] ?? 0
        let detected = Double(killed + timedOut)
        let valid = Double(killed + timedOut + survived)
        let covered = valid - Double(uncovered)

        return RunReport.Summary(
            killed: killed,
            survived: survived,
            timedOut: timedOut,
            inconclusive: counts["inconclusive"] ?? 0,
            errored: counts["errored"] ?? 0,
            notRun: counts["not-run"] ?? 0,
            rejected: rejected,
            equivalent: counts["equivalent"] ?? 0,
            uncovered: uncovered,
            cached: 0,
            expectedSurvivors: 0,
            score: .init(valid > 0 ? detected / valid : nil),
            scoreOfCoveredCode: .init(covered > 0 ? detected / covered : nil)
        )
    }
}

extension RunReport {

    /// The same report with these mutants, these test names, and this share.
    ///
    /// Everything else about a run - which tool, which package, what the compiler refused -
    /// is the same in every share of it, so it comes along unchanged.
    public func replacing(
        mutants: [Mutant],
        tests: [String],
        shard: String?,
        summary: Summary? = nil,
        files: [String: String]? = nil,
        expectations: Expectations? = nil
    ) -> Self {
        Self(
            schemaVersion: schemaVersion,
            tool: tool,
            scope: Scope(
                kind: scope.kind, since: scope.since, files: scope.files, shard: .init(shard)),
            summary: summary ?? self.summary,
            baseline: baseline,
            contendedBaseline: contendedBaseline,
            filesInstrumented: filesInstrumented,
            files: files ?? self.files,
            tests: tests,
            mutants: mutants,
            rejected: rejected,
            expectations: expectations ?? self.expectations,
            // One share's, because a merged report is about a package rather than about a
            // machine, and the copy any of them ran in is gone by the time it is merged.
            invocation: invocation
        )
    }
}
