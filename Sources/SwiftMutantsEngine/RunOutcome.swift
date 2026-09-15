// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsBuild
public import SwiftMutantsCore
public import SwiftMutantsDiscover
public import SwiftMutantsExecute
public import SwiftMutantsValidate

/// Everything one mutation run established.
public struct RunOutcome: Sendable {

    /// What became of each mutant, file by file, in catalogue order.
    public let results: [MutantResult]

    /// What the compiler refused, in its own words.
    public let rejected: [Rejection]

    /// The counts, and the score derived from them.
    public let summary: RunSummary

    /// How the instrumented tree behaved with nothing awake.
    public let baseline: Verdict

    /// How it behaved with every worker running at once, which is how the mutants run.
    ///
    /// The figure a deadline comes from, and one worth seeing on its own: a suite that
    /// takes twice as long beside itself is telling somebody something about their tests,
    /// and it is the number that decides what a mutant is allowed to cost.
    public let contendedBaseline: Verdict

    /// How many files were instrumented.
    public let filesInstrumented: Int

    /// What the run was about, when it was not about everything.
    ///
    /// A scoped run's score is a score about the scope. Saying so is not a caveat, it is
    /// the number's meaning: "seventy per cent" about four files somebody just wrote is a
    /// different sentence from "seventy per cent" about a package.
    public let scope: RunScope

    /// Where each file's bytes fall in the lines a person reads.
    ///
    /// Carried because every way of naming a place to somebody - a report, a warning, an
    /// editor - needs it, and it is worked out once while the sources are being read. A run
    /// that dropped it would have every later consumer open the files again, and they are
    /// not the same files by then: the copy is gone and the workspace may have moved on.
    public let positions: [WorkspaceRelativePath: LineIndex]

    /// What every file of the package digested to when it was read.
    ///
    /// Carried so that anything reading the sources afterwards can tell whether it is
    /// reading what was measured. A report that showed a line of code beside a verdict
    /// about a different line of code would be worse than one that showed no code.
    public let digests: [WorkspaceRelativePath: Digest]

    /// How this run started a mutant, so that somebody can start one themselves.
    ///
    /// The plan the trials were built from, kept rather than a finished command line: the
    /// line is built by the same function the runner used, so what somebody pastes is what
    /// ran rather than a plausible-looking reconstruction.
    public let plan: TestPlan?

    /// What the project's `[[mutation.expect]]` rows amounted to.
    ///
    /// Carried rather than folded into the summary, because "three expectations were met"
    /// and "one of them names a mutant that no longer exists" are different news and only
    /// the second one is somebody's to fix. The summary counts; this says what to do.
    public let expectations: Expectations.Verdict

    /// The project's own mutants that had nothing to anchor to.
    ///
    /// A row that stopped applying is a measurement silently not taken, and the moment to
    /// say so is now: somebody who has just moved the code still remembers why, and the
    /// row still means something to them. Months later it has been meaningless for a
    /// hundred commits and nobody can tell what it was for.
    public let unanchored: [UnanchoredMutant]

    /// Which share of the catalogue this machine took, when it took one.
    ///
    /// Apart from ``scope`` because it is a different kind of narrowing and the two
    /// combine: a run can be about what changed *and* be one machine of five. A score from
    /// one share is a score about that share, and a report that did not say so would be a
    /// number somebody quoted as though it were the package's.
    public let shard: Shard?

    /// Records everything one run established.
    public init(
        results: [MutantResult],
        rejected: [Rejection],
        summary: RunSummary,
        baseline: Verdict,
        contendedBaseline: Verdict,
        filesInstrumented: Int,
        scope: RunScope,
        positions: [WorkspaceRelativePath: LineIndex] = [:],
        digests: [WorkspaceRelativePath: Digest] = [:],
        expectations: Expectations.Verdict = .unasked,
        unanchored: [UnanchoredMutant] = [],
        plan: TestPlan? = nil,
        shard: Shard? = nil
    ) {
        self.results = results
        self.rejected = rejected
        self.summary = summary
        self.baseline = baseline
        self.contendedBaseline = contendedBaseline
        self.filesInstrumented = filesInstrumented
        self.scope = scope
        self.positions = positions
        self.digests = digests
        self.expectations = expectations
        self.unanchored = unanchored
        self.plan = plan
        self.shard = shard
    }
}

/// What a run was asked to measure.
public enum RunScope: Sendable, Hashable {

    /// Every file the package has.
    case everything

    /// Only the files that differ from a reference, including work not yet committed.
    case changed(since: String, files: Int)
}

/// A run could not be carried out.
public struct RunError: Error, Hashable, CustomStringConvertible {

    /// What went wrong, in the words a fix needs.
    public let description: String

    init(_ description: String) { self.description = description }
}

/// What a run is doing, for somebody watching it.
public enum RunStage: Sendable, Hashable {
    case snapshotting
    case discovering

    /// Building the package as the user wrote it, before anything is done to it.
    ///
    /// If this fails the package does not build, and every later complaint would have been
    /// about something this tool did. It also produces the compiled interfaces that let
    /// each module be validated on its own afterwards.
    case priming
    case instrumenting(files: Int, mutants: Int)
    case validating(Validator.Progress)
    case building
    case proving
    case baseline

    /// Working out whose failure a red baseline is, by building the package as written.
    ///
    /// Only ever reached when the run is about to stop, and said out loud because an
    /// unexplained second build after a failure looks like the tool having lost its place.
    case attributing

    /// How long each mutant will be given, and where that came from.
    case calibrated(Duration)

    /// Asking each test what it reaches, so a mutant can be offered only the tests that
    /// matter rather than the whole suite.
    case probing(tests: Int)

    /// What the probe found: how many mutants nothing reaches, and how many tests an
    /// average mutant will actually face.
    case covered(uncovered: Int, averageTests: Double)

    /// How many tests the probe could not establish anything about.
    ///
    /// Said out loud because the answer it forces is slower and the answer it prevents is
    /// wrong. A test whose probe did not finish is offered to every mutant, so a run with
    /// several of them costs more than it should - and a reader seeing that cost deserves
    /// to know it was bought rather than lost.
    case unmeasured(tests: Int)

    /// How many tests did not have to be asked what they reach, out of how many there are.
    ///
    /// The probe is one process per test, so this is the other large saving a warm run
    /// makes - and, like the first, one a reader deserves to be told about rather than to
    /// infer from how quickly it went past.
    case recalled(known: Int, total: Int)

    /// The run was narrowed to what changed, and to how many files.
    case scoped(since: String, files: Int)

    /// How many mutants there are, and how many processes they will take.
    ///
    /// The saving, said out loud. A mutant nothing reaches takes none at all, and mutants
    /// no test shares take one between them - so the gap between these two numbers is what
    /// the coverage bought.
    /// How many mutants a previous run already answered, out of how many there are.
    ///
    /// Said out loud because it is the largest saving this tool has and the one easiest to
    /// be wrong about. A reader who sees six hundred mutants answered in a second deserves
    /// to be told why, and to be able to turn it off.
    /// How many of the catalogue this machine took, and which share it is.
    ///
    /// Said out loud because a score from one share is a score about that share, and a
    /// reader who was handed the number without the sentence would quote it as the
    /// package's.
    /// Asking the compiler which of these survivors it turns into the original program.
    case provingEquivalence(survivors: Int)

    /// What it said: how many could never have been caught, and how many are another
    /// mutant written twice.
    case proved(equivalent: Int, duplicates: Int)

    case sharded(Shard, mine: Int, total: Int)

    case remembered(known: Int, total: Int)

    case running(total: Int, processes: Int)
    case finished(MutantResult)
}
