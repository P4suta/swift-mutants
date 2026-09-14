// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The report is a value: it names nothing from any other module in its own shape, which is
// what lets anything read one without linking the engine that made it.

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

    /// What every file of the package digested to when it was read.
    ///
    /// Every file, not only the ones with mutants in them, because the score rests on all
    /// of them. Anything that reads the sources afterwards - a projection that has to show
    /// the code beside the verdict - can tell whether it is reading what was measured.
    public let files: [String: String]

    /// Every test any mutant was offered, in a fixed order.
    ///
    /// Written once and referred to by position, because the names repeat: a package with
    /// six hundred mutants facing forty tests each would otherwise carry twenty-four
    /// thousand copies of four hundred strings. The order is the run's own.
    public let tests: [String]

    /// What became of each mutant, in catalogue order.
    public let mutants: [Mutant]

    /// What the compiler refused, in its own words.
    public let rejected: [Refusal]

    /// What the project's `[[mutation.expect]]` rows amounted to.
    ///
    /// Here rather than only on stdout, because the report is what a build reads. A job
    /// that had to parse a summary line to learn which expectation went wrong is a job that
    /// breaks the next time a sentence is reworded.
    public let expectations: Expectations

    /// Records a report directly, for a caller that has the pieces already.
    public init(
        schemaVersion: Int,
        tool: Tool,
        scope: Scope,
        summary: Summary,
        baseline: Behaviour,
        contendedBaseline: Behaviour,
        filesInstrumented: Int,
        files: [String: String],
        tests: [String],
        mutants: [Mutant],
        rejected: [Refusal],
        expectations: Expectations
    ) {
        self.schemaVersion = schemaVersion
        self.tool = tool
        self.scope = scope
        self.summary = summary
        self.baseline = baseline
        self.contendedBaseline = contendedBaseline
        self.filesInstrumented = filesInstrumented
        self.files = files
        self.tests = tests
        self.mutants = mutants
        self.rejected = rejected
        self.expectations = expectations
    }

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

        /// Which share of the catalogue this machine took, as `2/5`.
        ///
        /// A score from one share is a score about that share. Saying so is not a caveat,
        /// it is the number's meaning - and it is what `report merge` reads to know these
        /// are pieces of one run rather than several runs of one package.
        public let shard: Reported<String>
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

        /// The bytes it replaced, as the user wrote them.
        public let original: String

        /// The bytes it put there instead.
        ///
        /// Carried so that a report says what a mutant was rather than naming a rule and a
        /// position and sending a reader back to a file that may have moved on.
        public let replacement: String

        /// What became of it.
        public let outcome: String

        /// The tests that failed with it awake, in the order their failures arrived.
        public let killedBy: [String]

        /// Which tests ran with it awake, as positions in ``RunReport/tests``.
        ///
        /// The tests that looked at a survivor and said nothing are the whole of what to do
        /// about it - one of them is where the missing assertion belongs - so a report that
        /// only counted them would leave a reader to find them among four hundred.
        public let ran: [Int]

        /// How many tests it was offered and began.
        public let testsStarted: Int

        /// How many times it had to be run. More than once means the first attempt ran out
        /// of time and was tried again on a quiet machine.
        public let attempts: Int

        /// How long the run that decided it took.
        public let durationMilliseconds: Int

        /// Records what became of one mutant.
        public init(
            id: String,
            path: String,
            line: Reported<Int>,
            column: Reported<Int>,
            span: Span,
            rule: String,
            original: String,
            replacement: String,
            outcome: String,
            killedBy: [String],
            ran: [Int],
            testsStarted: Int,
            attempts: Int,
            durationMilliseconds: Int
        ) {
            self.id = id
            self.path = path
            self.line = line
            self.column = column
            self.span = span
            self.rule = rule
            self.original = original
            self.replacement = replacement
            self.outcome = outcome
            self.killedBy = killedBy
            self.ran = ran
            self.testsStarted = testsStarted
            self.attempts = attempts
            self.durationMilliseconds = durationMilliseconds
        }
    }

    /// A half-open range of bytes.
    public struct Span: Codable, Sendable, Hashable {

        /// The first byte, counted from the start of the file the user wrote.
        public let start: Int

        /// One past the last byte.
        public let end: Int

        /// Records a half-open range of bytes.
        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
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
