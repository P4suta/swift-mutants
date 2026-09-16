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

    /// How this run started a mutant, so somebody can start one themselves.
    ///
    /// A summary says a hundred and eighty things survived; the work is one at a time, and
    /// the fastest way into one is to run it under a debugger. This is what `explain` turns
    /// into that command.
    public let invocation: Invocation

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
        expectations: Expectations,
        invocation: Invocation
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
        self.invocation = invocation
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

        /// Mutants that ran out of time twice, the second time with this run idle around
        /// them. Counted as detections and always shown apart from kills.
        ///
        /// The retry removes the contention this run made, which is all it can remove. A
        /// machine loaded by something else is one both attempts wait on, so a reader who
        /// measured on a busy machine should read this column as the weakest in the
        /// report.
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

        /// The tests that declared themselves disabled and did not run.
        ///
        /// In the report as well as in what a run says out loud, because the narration
        /// scrolls past and this is what a gate and an audit read. Anything only a skipped
        /// test covers reports as surviving however good that test is, and somebody looking
        /// at a list of permanent survivors needs the reason to be in the same document.
        public let testsSkipped: [String]

        /// One behaviour, with no skips unless there were some.
        ///
        /// The default is what every caller but the reader wants: a fixture, a merge and a
        /// projection are all about a run whose tests ran.
        public init(
            outcome: String,
            testsStarted: Int,
            durationMilliseconds: Int,
            testsSkipped: [String] = []
        ) {
            self.outcome = outcome
            self.testsStarted = testsStarted
            self.durationMilliseconds = durationMilliseconds
            self.testsSkipped = testsSkipped
        }

        /// Reads one, tolerating a report written before this answer existed.
        ///
        /// Absent means absent, not undecodable. `ReportStore.read` answers a report it
        /// cannot decode with `nil`, which every caller reads as "nobody has run this yet"
        /// - so a required new key would turn every report written by an earlier build into
        /// a run that never happened, silently, which is the shape this project exists to
        /// refuse.
        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                outcome: try fields.decode(String.self, forKey: .outcome),
                testsStarted: try fields.decode(Int.self, forKey: .testsStarted),
                durationMilliseconds: try fields.decode(
                    Int.self, forKey: .durationMilliseconds),
                testsSkipped: try fields.decodeIfPresent(
                    [String].self, forKey: .testsSkipped) ?? []
            )
        }
    }
}
