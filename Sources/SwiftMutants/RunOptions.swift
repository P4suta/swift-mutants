// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Selection and test deadlines for a package measurement.
public struct RunOptions: Sendable, Equatable {
    /// Package-relative globs to include; an empty list includes all production Swift sources.
    public var include: [String]
    /// Package-relative globs to exclude.
    public var exclude: [String]
    /// SwiftPM regular expressions selecting tests.
    public var filter: [String]
    /// SwiftPM regular expressions excluding tests.
    public var skip: [String]
    /// A positive deadline for each baseline or complete mutant suite.
    public var timeout: Duration?
    /// Full mutation identities to measure; an empty list selects all candidates.
    public var mutantIDs: [String]

    /// Empty file selection includes every package-owned production Swift source.
    /// Filters and skips use SwiftPM regular expressions.
    /// A timeout applies to each baseline and mutant, excluding builds.
    /// Without a timeout, baselines get five minutes and mutants get the greater of thirty seconds and five times the slowest baseline.
    public init(
        include: [String] = [],
        exclude: [String] = [],
        filter: [String] = [],
        skip: [String] = [],
        timeout: Duration? = nil,
        mutantIDs: [String] = []
    ) {
        self.include = include
        self.exclude = exclude
        self.filter = filter
        self.skip = skip
        self.timeout = timeout
        self.mutantIDs = mutantIDs
    }
}

/// The operation reporting progress or a prerequisite failure.
public enum RunStage: String, Sendable, Equatable {
    case input, snapshot, toolchain, discovery, build, baseline, instrumentation, measurement,
        cleanup
}

/// The source variant being built by SwiftPM.
public enum BuildKind: Sendable, Equatable {
    case original
    case instrumented
    case individual(mutantID: String)
}

/// Progress delivered synchronously on the measurement task without console output.
public enum RunEvent: Sendable, Equatable {
    case stage(RunStage)
    case building(BuildKind)
    case baseline(completed: Int, total: Int)
    case measuring(mutation: Mutation, completed: Int, total: Int)
    case measured(MutationResult)
    case finished(MutationReport)
}

/// A failed measurement prerequisite and its diagnostic.
public struct MutationTestingError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The failed prerequisite or cleanup operation.
    public let stage: RunStage
    /// The cause and available command output.
    public let diagnostic: String
    /// The stage followed by the diagnostic.
    public var description: String { "\(stage.rawValue): \(diagnostic)" }

    /// Creates a stage-specific failure.
    public init(stage: RunStage, diagnostic: String) {
        self.stage = stage
        self.diagnostic = diagnostic
    }
}
