// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// What a project asked for.
///
/// Every field has a default that is what the tool would do without a configuration at all,
/// so `.swift-mutants.toml` is a place to start editing rather than a prerequisite.
public struct Configuration: Sendable, Hashable {

    /// The configuration format this build understands.
    public static let version = 1

    /// What to mutate.
    public var mutation = Mutation()

    /// How to run the tests.
    public var test = Test()

    /// How much to do at once.
    public var execution = Execution()

    /// Whether to reuse outcomes already proven.
    public var cache = Cache()

    /// What should fail a build.
    public var policy = Policy()

    /// What to publish, and where.
    public var report = Report()

    /// Everything at its default.
    public init() {}

    /// What to mutate.
    public struct Mutation: Sendable, Hashable {
        /// Which tier of operators to use.
        public var profile: Profile = .balanced
        /// Whether to also replace whole function bodies.
        public var extreme = false
        /// Which files to mutate. Empty means all of them.
        public var include: [Glob] = []
        /// Which files to leave alone, applied after ``include``.
        public var exclude: [Glob] = []
        /// Which operator families to use. Empty means whatever the profile selects.
        public var operators: [String] = []
        /// Survivors this project has accounted for.
        public var expect: [Expectation] = []

        /// Creates the defaults.
        public init() {}
    }

    /// A tier of operators. Monotonically inclusive.
    public enum Profile: String, Sendable, Hashable, CaseIterable {
        case balanced
        case strong
        case all
    }

    /// A survivor a project has written down as evidence rather than as a gap.
    ///
    /// Not a skip list. The mutant is still executed on every invocation and never answered
    /// from the cache: surviving fulfils the expectation, being killed contradicts it, and
    /// an identity that has left the catalogue means the expectation is stale.
    public struct Expectation: Sendable, Hashable {
        // periphery:ignore - read from the file and not yet acted on, see below
        /// The full identity of the mutant, as sixty-four hexadecimal characters.
        ///
        /// Nothing consults it yet: `expectedSurvivors` is always nought and a project that
        /// writes an expectation gets no answer about it. The field stays because the file
        /// format is the promise, and breaking it would be worse than not keeping it yet.
        public var identity: String
        /// Why it is expected to survive.
        public var reason: String
    }

    /// How to run the tests.
    public struct Test: Sendable, Hashable {
        /// An argument vector, never a shell string.
        public var command: [String] = ["swift", "test"]
        /// How long a mutant may take. Unset derives one from the baseline.
        public var timeout: Duration?
        /// How much memory a mutant's tree may hold. Unset derives one from the baseline.
        public var memoryBytes: Int?
        /// How many times to measure the baseline. Every observation is kept.
        public var baselineRuns = 3

        /// Creates the defaults.
        public init() {}
    }

    /// How much to do at once.
    public struct Execution: Sendable, Hashable {
        /// How many mutants to measure at once. Unset derives one from the machine.
        public var jobs: Int?

        /// Which share of the catalogue this machine takes, when it takes one.
        ///
        /// Unset means all of it. A share is decided from each mutant's identity, so every
        /// machine works out the same answer without any of them talking to the others.
        public var shard: Shard?

        /// Creates the defaults.
        public init() {}
    }

    /// Whether to reuse outcomes already proven.
    public struct Cache: Sendable, Hashable {
        /// Which reuse mode to use.
        public var mode: CacheMode = .auto

        /// Creates the defaults.
        public init() {}
    }

    /// What should fail a build.
    public struct Policy: Sendable, Hashable {
        /// Whether an unexpected survivor exits 1.
        ///
        /// False by default. This tool does not fail a build unless it is asked to, in a
        /// terminal, a pipe and CI alike.
        public var strict = false
        /// A score below this exits 1, when strict.
        public var minimumScore = 0

        /// Creates the defaults.
        public init() {}
    }

    /// What to publish, and where.
    public struct Report: Sendable, Hashable {
        /// Where the published documents go, inside the project.
        public var directory = "reports/mutation"
        /// Which documents to publish.
        public var formats: [ReportFormat] = [.json, .html]
        /// The score at or above which a report reads as green.
        public var high = 80
        /// The score below which a report reads as red.
        public var low = 60

        /// Creates the defaults.
        public init() {}
    }
}

/// When outcomes a run has proven may be reused.
public enum CacheMode: String, Sendable, Hashable, CaseIterable {
    /// Reuse only for a test command this tool can reason about.
    case auto
    /// Reuse, on the caller's promise that the command is reproducible.
    ///
    /// Spelled `enabled` in Swift and `on` in the file: the file's vocabulary is shared
    /// with the sibling projects, and a two-letter identifier is one a reader has to look up.
    case enabled = "on"
    /// Never read and never write.
    case disabled = "off"
}

/// A document a run can publish.
public enum ReportFormat: String, Sendable, Hashable, CaseIterable {
    case json
    case html
    case sarif
}

/// A configuration this tool could not accept, and where the trouble is.
public struct ConfigurationError: Error, Hashable, CustomStringConvertible {

    /// The line the trouble is on, or zero when it is about the document as a whole.
    public let line: Int

    /// What is wrong, in the words a fix needs.
    public let reason: String

    /// The trouble with its position, ready to print.
    public var description: String {
        line > 0 ? "line \(line): \(reason)" : reason
    }

    init(line: Int, reason: String) {
        self.line = line
        self.reason = reason
    }
}
