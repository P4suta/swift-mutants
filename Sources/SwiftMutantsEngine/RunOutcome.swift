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

    /// How many files were instrumented.
    public let filesInstrumented: Int
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
    case instrumenting(files: Int, mutants: Int)
    case validating(Validator.Progress)
    case building
    case proving
    case baseline

    /// How long each mutant will be given, and where that came from.
    case calibrated(Duration)

    case running(total: Int)
    case finished(MutantResult)
}
