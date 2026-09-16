// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import SwiftMutantsRunner

/// Driving `xcodebuild`, once to build and once per mutant to run.
///
/// The shape the plan calls for: `build-for-testing` produces a `.xctestrun`, and every
/// mutant after that is one `test-without-building` against a copy of that document with
/// its own variable in it. One build, N runs - which is the same bargain the SwiftPM path
/// makes, paid for differently.
///
/// It costs more per mutant than the SwiftPM path, and that is a fact about `xcodebuild`
/// rather than a choice: launching an Xcode-built bundle the way the SwiftPM path launches
/// its own was tried first and produces no events at all, so there is no event stream to
/// watch and no first failure to stop at. What comes back instead is a result bundle, read
/// once the process has ended.
///
/// Every process goes through ``Runner``, so what this did is recorded whether or not
/// anybody asked - which is the point of having one place that starts processes.
public struct XcodeDriver: Sendable {

    /// Something `xcodebuild` would not do.
    public struct Refused: Error, Hashable, CustomStringConvertible {

        /// What went wrong, with xcodebuild's own words where it had any.
        public let description: String
    }

    private let root: URL
    private let runner: Runner
    private let executable: String
    private let environment: [String: String]

    /// Prepares to drive `xcodebuild` over the project at `root`.
    public init(
        root: URL,
        runner: Runner,
        executable: String = "/usr/bin/xcodebuild",
        environment: [String: String] = [:]
    ) {
        self.root = root
        self.runner = runner
        self.executable = executable
        self.environment = environment
    }

    /// The schemes this project has.
    public func schemes() async throws(Refused) -> [String] {
        let outcome = await run(["-list", "-json"], label: .describe)
        do {
            return try XcodeProject.schemes(in: outcome.standardOutputText)
        } catch {
            throw Refused(description: error.description)
        }
    }

    /// Builds the tests once, and says where the document that runs them went.
    ///
    /// `-derivedDataPath` per worker rather than shared, for the reason `.build` is: the
    /// databases underneath were not written for two processes at once.
    public func buildForTesting(
        scheme: String, destination: String, derivedData: URL
    ) async throws(Refused) -> URL {
        let outcome = await run(
            [
                "build-for-testing",
                "-scheme", scheme,
                "-destination", destination,
                "-derivedDataPath", derivedData.path,
            ],
            label: .build
        )
        guard outcome.exitCode == 0 else {
            // "would not build this project" is a claim about the project, and a deadline
            // of this tool's own is not evidence for it.
            // No deadline is passed to `xcodebuild` at all, so this can only be the
            // processor allowance. It is still worth asking: what is left of this branch
            // otherwise is a claim about the project.
            if let stopped = outcome.stoppedFromHere(after: nil) {
                throw Refused(
                    description: """
                        `xcodebuild build-for-testing` \(stopped). That is this tool's own \
                        limit rather than anything the project did.
                        """
                )
            }
            throw Refused(
                description: """
                    `xcodebuild build-for-testing` would not build this project, so nothing \
                    that follows would be about it. What it said:
                    \(Self.tail(of: outcome))
                    """
            )
        }
        do {
            return try XcodeProject.xctestrun(
                in: derivedData.appending(path: "Build/Products"))
        } catch {
            throw Refused(description: error.description)
        }
    }

    /// Runs one document and says what became of each test.
    ///
    /// The exit status is not the answer. `xcodebuild` exits non-zero when a test fails,
    /// which is exactly what a killed mutant looks like - and also when the project will
    /// not load, which is not. So the verdict comes from the result bundle, and a bundle
    /// that cannot be read is an error rather than a suite in which nothing failed.
    public func test(
        xctestrun: URL, destination: String, resultBundle: URL, onlyTests: [String]?
    ) async throws(Refused) -> TestResults {
        try? FileManager.default.removeItem(at: resultBundle)
        let selection = (onlyTests ?? []).map { "-only-testing:\($0)" }
        _ = await run(
            [
                "test-without-building",
                "-xctestrun", xctestrun.path,
                "-destination", destination,
                "-resultBundlePath", resultBundle.path,
            ] + selection,
            label: .mutant
        )
        return try await results(of: resultBundle)
    }

    /// What a result bundle says, read with the tool that owns its format.
    ///
    /// Never by reading the bundle's own files: it is a directory whose layout Xcode owns
    /// and changes, and `xcresulttool` is the only thing promised to keep working.
    func results(of bundle: URL) async throws(Refused) -> TestResults {
        let outcome = await runner.run(
            ProcessSpec(
                kind: .mutant,
                executable: "/usr/bin/xcrun",
                arguments: [
                    "xcresulttool", "get", "test-results", "tests",
                    "--path", bundle.path, "--compact",
                ],
                directory: root.path,
                environment: environment,
                timeout: nil
            ))
        do {
            return try TestResults(Data(outcome.standardOutput))
        } catch {
            throw Refused(
                description: """
                    the result bundle at \(bundle.path) could not be read, so nothing is \
                    known about what ran - which is not the same as nothing having failed. \
                    \(error.description)
                    """
            )
        }
    }

    /// One `xcodebuild` invocation, through the one place that starts processes.
    private func run(_ arguments: [String], label: ProcessSpec.Kind) async -> ProcessOutcome {
        await runner.run(
            ProcessSpec(
                kind: label,
                executable: executable,
                arguments: arguments,
                directory: root.path,
                environment: environment,
                timeout: nil
            ))
    }

    /// The last of what a failing command said, which is where xcodebuild puts the reason.
    private static func tail(of outcome: ProcessOutcome) -> String {
        let text =
            outcome.standardErrorText.isEmpty
            ? outcome.standardOutputText : outcome.standardErrorText
        return text.split(separator: "\n").suffix(20).joined(separator: "\n")
    }
}
