// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// The measured outcome of one source mutation.
public enum MutationOutcome: String, Sendable, Hashable, Codable, CaseIterable {
    case killed
    case survived
    case rejected
    case timedOut
    case errored
}

/// A mutation and the observations used to classify it.
public struct MutationResult: Sendable, Equatable, Encodable {
    /// The original source edit and identity.
    public let mutation: Mutation
    /// The measured classification.
    public let outcome: MutationOutcome
    /// Test wall time, or the duration of a failed individual build.
    public let durationMilliseconds: Int
    /// Diagnostics for a rejected edit or an incomplete execution.
    public let diagnostic: String?

    /// Creates one classified result.
    public init(
        mutation: Mutation,
        outcome: MutationOutcome,
        durationMilliseconds: Int = 0,
        diagnostic: String? = nil
    ) {
        self.mutation = mutation
        self.outcome = outcome
        self.durationMilliseconds = durationMilliseconds
        self.diagnostic = diagnostic
    }
}

/// Results for the mutations selected by one invocation.
public struct MutationReport: Sendable, Equatable, Encodable {
    /// Measurement JSON uses schema 3; historical reports used schema 2.
    public let schemaVersion = 3
    /// Every selected mutation in source order.
    public let results: [MutationResult]

    /// Creates a report whose counts and score derive from its results.
    public init(results: [MutationResult]) {
        self.results = results
    }

    /// Counts each result once, including unscored outcomes.
    public var summary: MutationSummary { MutationSummary(results: results) }

    /// Kills divided by kills plus survivors, absent for incomplete or empty measurements.
    public var score: Double? {
        let counts = summary
        guard counts.errored == 0, counts.timedOut == 0,
            counts.killed + counts.survived > 0
        else { return nil }
        return Double(counts.killed) / Double(counts.killed + counts.survived)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, results, summary, score
    }

    /// Encodes an absent score as JSON null.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(results, forKey: .results)
        try container.encode(summary, forKey: .summary)
        try container.encode(score, forKey: .score)
    }
}

/// Outcome counts for the selected mutations.
public struct MutationSummary: Sendable, Equatable, Encodable {
    /// Mutations detected by a recorded test failure.
    public let killed: Int
    /// Mutations whose complete selected suite passed.
    public let survived: Int
    /// Individual edits refused by the compiler.
    public let rejected: Int
    /// Mutations that exceeded the test deadline.
    public let timedOut: Int
    /// Mutations without a trustworthy test result.
    public let errored: Int
    /// The count of every selected mutation.
    public let total: Int

    init(results: [MutationResult]) {
        total = results.count
        let counts = Dictionary(grouping: results, by: \.outcome).mapValues(\.count)
        killed = counts[.killed, default: 0]
        survived = counts[.survived, default: 0]
        rejected = counts[.rejected, default: 0]
        timedOut = counts[.timedOut, default: 0]
        errored = counts[.errored, default: 0]
    }
}
