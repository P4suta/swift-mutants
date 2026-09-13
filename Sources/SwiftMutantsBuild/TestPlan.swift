// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// How to start the tests of a package that has already been built.
///
/// Built once by a build system and used for every mutant after that, which is the whole
/// economy of schemata: the toolchain compiles the tree one time, and each mutant costs one
/// process rather than one build.
public struct TestPlan: Sendable, Hashable {

    /// The program to start.
    public let executable: String

    /// What to pass it, before anything this tool needs to add.
    public let arguments: [String]

    /// What it needs in its environment to find its own frameworks.
    public let environment: [String: String]

    /// Where to start it.
    public let directory: String

    /// Which spelling of the event stream to ask for.
    public let eventStreamVersion: String

    /// Describes how to start a built test bundle.
    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String,
        eventStreamVersion: String = "6.3"
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.eventStreamVersion = eventStreamVersion
    }
}
