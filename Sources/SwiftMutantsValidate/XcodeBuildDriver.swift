// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import SwiftMutantsRunner

/// Asks Xcode to build a scheme's tests, and reports what the compiler said.
///
/// The Xcode path's answer to the same question the SwiftPM path asks: would this tree
/// compile, and if not, what did the compiler say about it. Everything downstream -
/// attributing each diagnostic to the mutant that caused it, asking again without those,
/// halving when the answers stop converging - is the same code, because a diagnostic is a
/// diagnostic whoever printed it.
///
/// Measured on Xcode 26.6 rather than assumed, and two of the three findings changed this.
///
/// - `xcodebuild` prints `path:line:col: error: message`, which is the form validation
///   already reads. No translation layer, and nothing to keep in step with Xcode.
/// - **How much it reports is a race.** Every error inside a file that failed comes back,
///   but whether a second file's errors come back depends on how far the parallel compile
///   got - measured three times each way, with the same two broken files, and the answer
///   differed between runs. So a round surfaces at least one file's worth of rejections and
///   often more, and the loop converges by asking again without them. The worst case is one
///   build per file that has a rejection in it.
/// - **`-continue-building-after-errors` does not help here**, which is why it is not
///   passed. It is what gives the SwiftPM path its handful of rounds, and under `xcodebuild`
///   the same three-times-each-way measurement found no difference - the variation was the
///   race above. Passing it would also mean setting `OTHER_SWIFT_FLAGS` on the command line,
///   which *replaces* whatever the project set for itself: a flag that buys nothing and
///   silently changes how somebody's package is compiled.
public struct XcodeBuildDriver: TypecheckDriver {

    private let runner: Runner
    private let executable: String
    private let root: String
    private let scheme: String
    private let destination: String
    private let derivedData: String
    private let environment: [String: String]
    private let timeout: Duration?

    /// Prepares to build `scheme` of the project at `root` into `derivedData`.
    public init(
        runner: Runner,
        executable: String = "/usr/bin/xcodebuild",
        root: String,
        scheme: String,
        destination: String,
        derivedData: String,
        environment: [String: String] = [:],
        timeout: Duration? = .seconds(1800)
    ) {
        self.runner = runner
        self.executable = executable
        self.root = root
        self.scheme = scheme
        self.destination = destination
        self.derivedData = derivedData
        self.environment = environment
        self.timeout = timeout
    }

    /// What the arguments amount to, so that a test can assert on them without a build.
    ///
    /// A value rather than a literal inside the call, because what this asks for is the
    /// whole of the driver's behaviour: everything else here is handing bytes about.
    public var arguments: [String] {
        [
            "build-for-testing",
            "-scheme", scheme,
            "-destination", destination,
            // Per worker rather than shared, for the reason a scratch path is: the
            // databases underneath were not written for two processes at once.
            "-derivedDataPath", derivedData,
        ]
    }

    /// Builds the scheme, ignoring the paths it is handed.
    ///
    /// The paths are already in the tree - validation wrote them there - and a build is
    /// about a scheme rather than about a list of files. They are accepted and ignored
    /// rather than refused, because the protocol is what lets a test put a scripted
    /// compiler in this place.
    public func typecheck(_ paths: [String]) async -> CompilerOutput {
        let outcome = await runner.run(
            ProcessSpec(
                kind: .build,
                executable: executable,
                arguments: arguments,
                directory: root,
                environment: environment,
                timeout: timeout
            )
        )
        // Both streams, because xcodebuild puts diagnostics on standard output and its own
        // failures on standard error, and a reader that took one of them would miss
        // whichever half mattered.
        let said =
            String(decoding: outcome.standardError, as: UTF8.self)
            + String(decoding: outcome.standardOutput, as: UTF8.self)
        return CompilerOutput(exitCode: Int32(truncatingIfNeeded: outcome.exitCode), text: said)
    }
}
