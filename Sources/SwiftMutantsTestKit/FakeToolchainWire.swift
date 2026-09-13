// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// What a scripted toolchain should do when it is asked something.
///
/// The shape is shared between the harness that writes a rule table and the executable
/// that answers from one, through a JSON file rather than through a Swift dependency: the
/// fake is a *process*, so the only thing the two halves can share is bytes.
public struct FakeToolchainRule: Codable, Sendable {

    /// Every one of these must appear in the argument vector, in this order.
    ///
    /// A subsequence rather than an exact vector, because a test scripts the part of the
    /// command it cares about - `["build", "--build-tests"]` - and should not have to
    /// restate the scratch path the engine happened to pick.
    public var whenArgumentsContain: [String]

    /// What to exit with.
    public var exitCode: Int32 = 0

    /// What to print to standard output.
    public var standardOutput: String = ""

    /// What to print to standard error.
    public var standardError: String = ""

    /// How long to take before answering, in milliseconds.
    ///
    /// This is how a hang is scripted. A toolchain that never returns cannot be installed,
    /// so without it the supervisor's deadline could only be tested against the real thing.
    public var delayMilliseconds: Int = 0

    /// Files to create before exiting, path to contents.
    ///
    /// A build that produces nothing is indistinguishable from a build that failed, so a
    /// scripted build has to be able to leave its products behind.
    public var writes: [String: String] = [:]

    /// Scripts one answer.
    ///
    /// A synthesised memberwise initialiser would be internal, and the harness that writes
    /// a rule table lives in another module from the executable that answers from one.
    public init(
        whenArgumentsContain: [String],
        exitCode: Int32 = 0,
        standardOutput: String = "",
        standardError: String = "",
        delayMilliseconds: Int = 0,
        writes: [String: String] = [:]
    ) {
        self.whenArgumentsContain = whenArgumentsContain
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.delayMilliseconds = delayMilliseconds
        self.writes = writes
    }
}

/// One call the scripted toolchain answered.
public struct FakeToolchainCall: Codable, Sendable {

    /// The whole argument vector, argv[0] included.
    public var arguments: [String]

    /// Where it was started.
    public var directory: String

    /// The variables it was given, and the values of the few that are paths or flags.
    ///
    /// A call log is uploaded as a CI artefact, so only variables that are flag lists or
    /// paths keep their values. Everything else is recorded by name alone.
    public var environment: [String: String]

    /// The names of every variable it was given.
    public var environmentNames: [String]

    /// Records one call.
    public init(
        arguments: [String],
        directory: String,
        environment: [String: String],
        environmentNames: [String]
    ) {
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.environmentNames = environmentNames
    }
}

/// Where the two halves agree to meet.
public enum FakeToolchainEnvironment {
    /// The rule table to answer from.
    public static let ruleTable = "SWIFT_MUTANTS_FAKE_RULES"
    /// The file to append a record of each call to.
    public static let callLog = "SWIFT_MUTANTS_FAKE_CALLS"
    /// Variables whose values are kept in the call log.
    public static let recordedValues = [
        "PATH", "SDKROOT", "DEVELOPER_DIR", "SWIFT_MUTANTS_ACTIVE", "SWIFT_MUTANTS_PROBE",
        "SWIFT_MUTANTS_TEST_TOKEN", "SWIFT_MUTANTS", "TMPDIR",
    ]
    /// What a scripted toolchain exits with when no rule matched.
    ///
    /// Distinct from anything a real toolchain returns, so a test can never pass on a
    /// command nobody scripted.
    public static let unscriptedExitCode: Int32 = 97
}
