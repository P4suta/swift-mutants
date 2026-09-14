// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore
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

    /// Records everything one run established.
    public init(
        results: [MutantResult],
        rejected: [Rejection],
        summary: RunSummary,
        baseline: Verdict,
        contendedBaseline: Verdict,
        filesInstrumented: Int,
        scope: RunScope,
        positions: [WorkspaceRelativePath: LineIndex] = [:]
    ) {
        self.results = results
        self.rejected = rejected
        self.summary = summary
        self.baseline = baseline
        self.contendedBaseline = contendedBaseline
        self.filesInstrumented = filesInstrumented
        self.scope = scope
        self.positions = positions
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

    /// How long each mutant will be given, and where that came from.
    case calibrated(Duration)

    /// Asking each test what it reaches, so a mutant can be offered only the tests that
    /// matter rather than the whole suite.
    case probing(tests: Int)

    /// What the probe found: how many mutants nothing reaches, and how many tests an
    /// average mutant will actually face.
    case covered(uncovered: Int, averageTests: Double)

    /// The run was narrowed to what changed, and to how many files.
    case scoped(since: String, files: Int)

    /// How many mutants there are, and how many processes they will take.
    ///
    /// The saving, said out loud. A mutant nothing reaches takes none at all, and mutants
    /// no test shares take one between them - so the gap between these two numbers is what
    /// the coverage bought.
    case running(total: Int, processes: Int)
    case finished(MutantResult)
}
