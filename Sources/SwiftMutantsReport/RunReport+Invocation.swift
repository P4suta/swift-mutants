// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

extension RunReport {

    /// How a run started a mutant.
    ///
    /// The pieces rather than a finished line, because the line is built by the same
    /// function the runner used. A command assembled separately by whatever prints it is a
    /// plausible-looking line that works until the day the runner adds a flag - and then it
    /// silently runs a different program, the mutant behaves differently under the debugger
    /// than it did in the report, and nobody can tell why.
    ///
    /// The environment is deliberately not here. What a reader needs is the two variables
    /// this tool sets, and those are known; carrying the rest would put whatever a developer
    /// has exported - tokens, keys - into a file that ends up in a bug report.
    public struct Invocation: Codable, Sendable, Hashable {

        /// The test bundle the run launched, in the copy it was measured in.
        public let executable: String

        /// The arguments the run was given, before the ones added to watch it.
        public let arguments: [String]

        /// Where it was started.
        public let directory: String

        /// Which spelling of the event stream it asked for.
        public let eventStreamVersion: String

        /// The variables the run worked out, which a command reproducing it needs.
        ///
        /// Only those. On a Mac a test bundle is a dylib that needs `Testing.framework` on
        /// its search path, and a command without it fails to load and reads as a bug in
        /// the package; everything else the run inherited from whoever started it stays
        /// out, because that is where their tokens are.
        public let environment: [String: String]

        /// Whether the copy it ran in is still there.
        ///
        /// A run works inside a disposable snapshot, so the answer is usually no - and a
        /// command naming a directory that no longer exists is a command somebody pastes
        /// and then has to work out why it failed. Saying so is the difference between a
        /// line that helps and a line that wastes ten minutes.
        public let kept: Bool

        /// Records how a run started a mutant.
        public init(
            executable: String,
            arguments: [String],
            directory: String,
            eventStreamVersion: String,
            environment: [String: String],
            kept: Bool
        ) {
            self.executable = executable
            self.arguments = arguments
            self.directory = directory
            self.eventStreamVersion = eventStreamVersion
            self.environment = environment
            self.kept = kept
        }

        /// Whether there is a command to show at all.
        ///
        /// A run that never got as far as building has no plan, and saying nothing is the
        /// truth: there is no command that would reproduce it.
        public var isKnown: Bool { !executable.isEmpty }
    }
}
