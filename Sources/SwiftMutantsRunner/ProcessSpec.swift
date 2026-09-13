// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// One command a run wants to start.
///
/// Assembled as a value rather than passed as loose arguments, so that the thing which
/// starts processes has exactly one shape of input and exactly one place to record it.
public struct ProcessSpec: Sendable, Hashable {

    /// What kind of command this is, for a reader scanning the account.
    ///
    /// An enum rather than a string, which is the whole point: recording at the choke point
    /// means a call site cannot forget to record, and a closed label means it cannot get
    /// the label wrong either. A new kind of command is a new case here, which is a change
    /// somebody reviews.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// `swift --version`, or whatever else establishes that a toolchain is there.
        case versionProbe = "version-probe"
        /// Asking the package manager what a package contains.
        case describe
        /// Building, including building tests.
        case build
        /// Type-checking an instrumented tree, for compile validation.
        case typecheck
        /// Emitting SIL, for trivial-compiler-equivalence.
        case emitSIL = "emit-sil"
        /// The baseline suite, with nothing activated.
        case baseline
        /// Profiling a test to find out what it reaches.
        case coverage
        /// One mutant, activated.
        case mutant
        /// One probe run against the probe tree.
        case probe
        /// Something a test in this repository scripted.
        case testFixture = "test-fixture"
    }

    /// What kind of command this is.
    public let kind: Kind

    /// The program to start. An absolute path, never a shell string.
    public let executable: String

    /// Its arguments, verbatim. Never handed to a shell.
    public let arguments: [String]

    /// The directory to start it in.
    public let directory: String

    /// The whole environment it gets.
    ///
    /// Whole rather than added to the ambient one: a run that inherited whatever happened to
    /// be set could not be reproduced from its own recording, and the recording would have
    /// to name variables the run never chose.
    public let environment: [String: String]

    /// How long it may take, if it has a deadline.
    public let timeout: Duration?

    /// Describes one command.
    public init(
        kind: Kind,
        executable: String,
        arguments: [String],
        directory: String,
        environment: [String: String],
        timeout: Duration?
    ) {
        self.kind = kind
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.timeout = timeout
    }
}

/// What became of a command.
public struct ProcessOutcome: Sendable {

    /// Its exit status, or `-1` when it never became a process.
    public let exitCode: Int

    /// The signal that ended it, if one did.
    public let signal: Int?

    /// Whether it was stopped for overrunning its deadline.
    public let timedOut: Bool

    /// How long it ran.
    public let durationMilliseconds: Int

    /// The first ``Runner/outputLimit`` bytes it printed to standard output.
    public let standardOutput: [UInt8]

    /// The first ``Runner/outputLimit`` bytes it printed to standard error.
    public let standardError: [UInt8]

    /// How much it printed to standard output in total, retained or not.
    public let standardOutputBytes: Int

    /// How much it printed to standard error in total, retained or not.
    public let standardErrorBytes: Int

    /// Why it could not be started, when it could not be.
    public let startFailure: String?

    /// Where its record sits in the run's account.
    ///
    /// Handed back so that an error travelling up three layers can still say which
    /// recorded command it was about.
    public let traceSequence: Int
}
