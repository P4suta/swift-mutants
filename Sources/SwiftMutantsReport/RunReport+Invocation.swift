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

        /// Every test bundle the run built, in the copy it was measured in.
        ///
        /// One used to be enough, because a package built one. It builds one per test
        /// target now, and a mutant faces the ones its tests live in - so a report
        /// carrying a single bundle would hand somebody a command that runs a different
        /// target from the one that measured their mutant, finds nothing, and reads as
        /// this tool having lied to them.
        public let bundles: [LaunchedBundle]

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
            bundles: [LaunchedBundle],
            directory: String,
            eventStreamVersion: String,
            environment: [String: String],
            kept: Bool
        ) {
            self.bundles = bundles
            self.directory = directory
            self.eventStreamVersion = eventStreamVersion
            self.environment = environment
            self.kept = kept
        }

        /// Whether there is a command to show at all.
        ///
        /// A run that never got as far as building has no plan, and saying nothing is the
        /// truth: there is no command that would reproduce it.
        public var isKnown: Bool { bundles.contains { !$0.executable.isEmpty } }

        /// The bundles these tests live in, or all of them when that cannot be told.
        ///
        /// A test names its own bundle - swift-testing identifies it as
        /// `Module.Suite/name()` - so the tests a mutant was offered say which bundles ran
        /// it. A name this cannot place widens rather than narrows, because a command that
        /// runs too much reproduces the mutant and a command that runs too little does not.
        public func covering(_ tests: [String]) -> [LaunchedBundle] {
            guard !tests.isEmpty else { return bundles }
            var wanted: Set<String> = []
            for test in tests {
                guard let dot = test.firstIndex(of: "."), !test[test.startIndex..<dot].isEmpty,
                    !test[test.startIndex..<dot].contains("/")
                else { return bundles }
                wanted.insert(String(test[test.startIndex..<dot]))
            }
            let mine = bundles.filter { wanted.contains($0.module) }
            return mine.isEmpty ? bundles : mine
        }
    }
}

extension RunReport {

    /// One test bundle, and how the run started it.
    public struct LaunchedBundle: Codable, Sendable, Hashable {

        /// The test target it was built from, which is the name its tests wear.
        public let module: String

        /// The program that loads it.
        public let executable: String

        /// The arguments the run was given, before the ones added to watch it.
        public let arguments: [String]

        /// Records one bundle.
        public init(module: String, executable: String, arguments: [String]) {
            self.module = module
            self.executable = executable
            self.arguments = arguments
        }
    }
}
