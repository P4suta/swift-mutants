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

    /// The test target this bundle was built from.
    ///
    /// The name a test wears in front of its own: swift-testing identifies a test as
    /// `Module.Suite/name()`, and a test target's module is the bundle it is built into.
    /// That is what lets a set of reaching tests say which bundles a mutant has to face,
    /// now that a package builds one bundle per test target rather than one in total.
    public let module: String

    /// The variables this plan worked out, as opposed to the ones it was handed.
    ///
    /// A subset of ``environment``, kept apart because these are the ones a command that
    /// reproduces a run needs and the ones it is safe to write down. On a Mac a test bundle
    /// is a dylib that needs `Testing.framework` on its search path; a command without that
    /// fails with `Library not loaded` and reads as a bug in the package rather than a
    /// missing variable. Everything else in the environment was inherited from whoever
    /// started the run, and that is where their tokens are.
    public let derived: [String: String]

    /// Describes how to start a built test bundle.
    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String,
        eventStreamVersion: String = "6.3",
        derived: [String: String] = [:],
        module: String = ""
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.eventStreamVersion = eventStreamVersion
        self.derived = derived
        self.module = module
    }
}
