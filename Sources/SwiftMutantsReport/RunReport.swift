// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import SwiftMutantsCore
public import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsValidate

/// The account a run gives of itself.
///
/// Everything else is a projection of this: the summary a person reads, the file an
/// ecosystem reads, the cache that decides what a later run may skip, the exit code. So
/// this is the artefact that has to be complete, stable, and honest about what it does not
/// know - and the only one whose shape is a promise to anybody outside this repository.
///
/// Three rules it keeps, each of which is a way a report can lie:
///
/// - Every column appears every time, including the zeroes. A key that vanished when it was
///   zero would leave a reader unable to tell "none" from "this version does not say".
/// - A number nobody measured is `null`, never a sentinel. Zero reads as "caught none" and
///   one as "caught all"; both are claims about tests that never ran.
/// - Places are named the way the repository names them. The copy a run happened in is gone
///   by the time anybody reads this.
public struct RunReport: Codable, Sendable, Hashable {

    /// Which shape this is. Bumped when a reader would have to be changed.
    public let schemaVersion: Int

    /// Which build made it.
    public let tool: Tool

    /// What the run was asked to measure.
    public let scope: Scope

    /// The counts, and the two scores derived from them.
    public let summary: Summary

    /// How the instrumented tree behaved with nothing awake.
    public let baseline: Behaviour

    /// How it behaved with every worker running at once, which is how the mutants ran.
    public let contendedBaseline: Behaviour

    /// How many files were instrumented.
    public let filesInstrumented: Int

    /// What became of each mutant, in catalogue order.
    public let mutants: [Mutant]

    /// What the compiler refused, in its own words.
    public let rejected: [Refusal]

    /// Which build made a report.
    public struct Tool: Codable, Sendable, Hashable {

        /// Always `swift-mutants`, so a reader can tell one of these from a neighbour's.
        public let name: String

        /// The build that produced the report.
        public let version: String
    }

    /// What a run was about, when it was not about everything.
    public struct Scope: Codable, Sendable, Hashable {
        /// `everything`, or `changed`.
        public let kind: String
        /// The reference a scoped run was measured against.
        public let since: Reported<String>
        /// How many files it came to.
        public let files: Reported<Int>
    }

    /// The counts, and what they amount to.
    public struct Summary: Codable, Sendable, Hashable {

        /// Mutants at least one test failed on.
        public let killed: Int

        /// Mutants the whole suite passed with awake. Each one is a test worth writing or
        /// a line worth deleting.
        public let survived: Int

        /// Mutants that ran out of time twice, the second time on a quiet machine. Counted
        /// as detections and always shown apart from kills.
        public let timedOut: Int

        /// Mutants nothing could be said about, which are in neither column of the score.
        public let inconclusive: Int

        /// Mutants this tool itself failed on. Kept out of the score rather than read as a
        /// suite that passed.
        public let errored: Int

        /// Mutants outside the selection, on another shard, or cut short by an interrupt.
        public let notRun: Int

        /// Mutants the compiler would not accept, listed in full under ``rejected``.
        public let rejected: Int

        /// Mutants proved to compile to the same program as the original.
        public let equivalent: Int

        /// Survivors no test reaches at all - a subset of ``survived``, and usually the
        /// cheapest thing on the list to deal with.
        public let uncovered: Int

        /// Answers taken from a previous run rather than measured again.
        public let cached: Int

        /// Survivors a configuration asked to be checked, which leave the score's
        /// denominator because they are evidence somebody wrote down rather than a gap.
        public let expectedSurvivors: Int

        /// How much of the code the tests are shown to protect, or nothing to go on.
        public let score: Reported<Double>

        /// How good the tests that exist are, which is a different question.
        public let scoreOfCoveredCode: Reported<Double>
    }

    /// How one run of the tests went.
    public struct Behaviour: Codable, Sendable, Hashable {

        /// What the run amounted to: `survived` is the only healthy answer here.
        public let outcome: String

        /// How many tests began.
        public let testsStarted: Int

        /// How long it took. Durations, never timestamps, so two reports can be diffed.
        public let durationMilliseconds: Int
    }

    /// What became of one mutant.
    public struct Mutant: Codable, Sendable, Hashable {
        /// The whole identity, not the twenty characters a terminal shows.
        public let id: String

        /// Where it is, as the repository names the file - never as the copy did.
        public let path: String

        /// Where a person looks. `null` when the run has no line index for the file.
        public let line: Reported<Int>

        /// The column, counted in UTF-8 bytes as the compiler counts them.
        public let column: Reported<Int>
        /// Where a program looks: the bytes of the file the user wrote.
        public let span: Span

        /// Which rule produced it, with the version that took part in its identity.
        public let rule: String

        /// What became of it.
        public let outcome: String

        /// The tests that failed with it awake, in the order their failures arrived.
        public let killedBy: [String]

        /// How many tests it was offered and began.
        public let testsStarted: Int

        /// How many times it had to be run. More than once means the first attempt ran out
        /// of time and was tried again on a quiet machine.
        public let attempts: Int

        /// How long the run that decided it took.
        public let durationMilliseconds: Int
    }

    /// A half-open range of bytes.
    public struct Span: Codable, Sendable, Hashable {

        /// The first byte, counted from the start of the file the user wrote.
        public let start: Int

        /// One past the last byte.
        public let end: Int
    }

    /// A value a report carries whether or not the run had one.
    ///
    /// Swift's synthesised encoding omits an optional property that is `nil`, which is the
    /// one thing a report must not do: a key that disappears when there is nothing to say
    /// leaves a reader unable to tell "nothing to say" from "this version does not say it",
    /// and those are different facts. This writes `null` and keeps the key.
    public struct Reported<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {

        /// What was measured, or nothing.
        public let value: Value?

        /// Carries a value, or the absence of one.
        public init(_ value: Value?) { self.value = value }

        /// Reads `null` as nothing and anything else as a value.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.value = container.decodeNil() ? nil : try container.decode(Value.self)
        }

        /// Writes the value, or `null` - never nothing at all.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            if let value {
                try container.encode(value)
            } else {
                try container.encodeNil()
            }
        }
    }

    /// One mutant the compiler would not accept, in the compiler's own words.
    ///
    /// The words rather than a code, because a rejection is a fact about somebody's
    /// program and the compiler said it better than this could. They exist only while the
    /// tree is instrumented, so a report that summarised them would be the last place they
    /// were ever written down.
    public struct Refusal: Codable, Sendable, Hashable {

        /// The whole identity of the mutant that was refused.
        public let id: String

        /// Which rule produced it.
        public let rule: String

        /// Where it was.
        public let span: Span

        /// What the compiler said about it.
        public let diagnostics: [Diagnostic]
    }

    /// One thing the compiler said.
    public struct Diagnostic: Codable, Sendable, Hashable {

        /// The file the compiler named.
        public let file: String

        /// The line it named.
        public let line: Int

        /// The column it named, counted in UTF-8 bytes as the compiler counts them.
        public let column: Int

        /// `error`, `warning` or `note`.
        public let severity: String

        /// What it said, with the severity and position stripped off the front.
        public let message: String
    }
}

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
        self.schemaVersion = 1
        self.tool = Tool(name: "swift-mutants", version: version)
        self.scope = Scope(of: outcome.scope)
        self.summary = Summary(of: outcome.summary)
        self.baseline = Behaviour(of: outcome.baseline)
        self.contendedBaseline = Behaviour(of: outcome.contendedBaseline)
        self.filesInstrumented = outcome.filesInstrumented
        self.mutants = outcome.results.map { result in
            let place = positions[result.path]?.position(of: result.span.start)
            return Mutant(
                id: result.identity.digest.hexadecimal,
                path: result.path.rendered,
                line: Reported(place?.line),
                column: Reported(place?.column),
                span: Span(start: result.span.start, end: result.span.end),
                rule: result.rule.rendered,
                outcome: result.verdict.outcome.rawValue,
                killedBy: result.verdict.killedBy,
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
    }

    /// The report as bytes, the same bytes every time.
    ///
    /// Sorted keys, because Swift deliberately varies the order a dictionary enumerates in
    /// between processes and a report that reordered itself could not be diffed or
    /// checksummed. Unescaped slashes, because a path is not a URL. Indented, because
    /// people read these in pull requests.
    public static func encoded(_ report: Self) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try encoder.encode(report)
    }
}

extension RunReport.Scope {
    init(of scope: RunScope) {
        switch scope {
        case .everything:
            self.init(kind: "everything", since: .init(nil), files: .init(nil))
        case .changed(let reference, let files):
            self.init(kind: "changed", since: .init(reference), files: .init(files))
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

extension RunReport.Behaviour {
    init(of verdict: Verdict) {
        self.init(
            outcome: verdict.outcome.rawValue,
            testsStarted: verdict.testsStarted,
            durationMilliseconds: verdict.durationMilliseconds
        )
    }
}
