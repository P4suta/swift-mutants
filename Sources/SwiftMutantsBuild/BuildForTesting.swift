// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import SwiftMutantsRunner

extension SwiftPackageManager {

    /// Builds the package's tests once, and says how to start them.
    ///
    /// Once is the point. Every mutant lives in the same tree behind its own guard, so the
    /// toolchain compiles the tree one time and each mutant after that costs one process
    /// rather than one build. What comes back is everything needed to start that process
    /// again with a different mutant awake.
    ///
    /// The scratch directory is per worker. SwiftPM's build database is not written for
    /// two builds at once, so workers get their own `--scratch-path`; the module cache and
    /// the dependency checkouts are the expensive shared things and they are not in there.
    public func buildForTesting(
        scratch: String,
        environment: [String: String] = [:],
        timeout: Duration? = .seconds(1800)
    ) async throws(BuildSystemError) -> TestPlan {
        try await build(scratch: scratch, environment: environment, timeout: timeout)
        let binary = try await binaryPath(scratch: scratch, environment: environment)
        let product = try Self.testProduct(in: binary)
        return try await plan(for: product, environment: environment)
    }

    private func build(
        scratch: String, environment: [String: String], timeout: Duration?
    ) async throws(BuildSystemError) {
        let outcome = await runner.run(
            ProcessSpec(
                kind: .build,
                executable: executable,
                arguments: [
                    "build", "--build-tests", "--scratch-path", scratch,
                    "--force-resolved-versions",
                ],
                directory: root.path,
                environment: environment,
                timeout: timeout
            )
        )
        try Self.expectSuccess(outcome, doing: "swift build --build-tests", in: root.path)
    }

    private func binaryPath(
        scratch: String, environment: [String: String]
    ) async throws(BuildSystemError) -> URL {
        let outcome = await runner.run(
            ProcessSpec(
                kind: .describe,
                executable: executable,
                arguments: ["build", "--show-bin-path", "--scratch-path", scratch],
                directory: root.path,
                environment: environment,
                timeout: .seconds(120)
            )
        )
        try Self.expectSuccess(outcome, doing: "swift build --show-bin-path", in: root.path)
        let path = String(decoding: outcome.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw BuildSystemError("`swift build --show-bin-path` said nothing")
        }
        return URL(filePath: path)
    }

    /// What the built tests are, as they appear on this platform.
    ///
    /// Asked of the filesystem rather than answered by a compile-time platform check,
    /// because the shape is a fact about what SwiftPM just produced. On macOS the product
    /// is a bundle directory holding a Mach-O that cannot be executed; elsewhere it is an
    /// executable. Guessing from the host would be wrong the first time someone
    /// cross-builds.
    static func testProduct(in binary: URL) throws(BuildSystemError) -> TestProduct {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: binary.path)
        } catch {
            throw BuildSystemError("\(binary.path) could not be read: \(error)")
        }
        let bundles = names.filter { $0.hasSuffix(".xctest") }.sorted()
        guard let name = bundles.first else {
            throw BuildSystemError(
                """
                no test bundle in \(binary.path). The package built, so this means it \
                declares no test target - there is nothing for a mutant to be caught by.
                """
            )
        }
        guard bundles.count == 1 else {
            throw BuildSystemError(
                """
                \(binary.path) holds more than one test bundle (\(bundles.joined(separator: ", "))). \
                swift-mutants runs one, and picking would be picking for you.
                """
            )
        }

        let bundle = binary.appending(path: name)
        let isBundle =
            (try? bundle.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isBundle == true else { return TestProduct(executable: bundle, isBundle: false) }

        let stem = String(name.dropLast(".xctest".count))
        return TestProduct(
            executable: bundle.appending(path: "Contents/MacOS/\(stem)"), isBundle: true)
    }

    /// The built tests, and whether they can be started directly.
    struct TestProduct {
        let executable: URL
        let isBundle: Bool
    }

    /// How to start a built test product.
    ///
    /// A bundle cannot be executed - it is linked as one - so it is loaded instead, by the
    /// same helper SwiftPM uses. See ADR 0003 for why this rather than `xctest`, which
    /// swallows the arguments the event stream needs, or `swift test`, which re-reads the
    /// package manifest once per mutant.
    private func plan(
        for product: TestProduct, environment: [String: String]
    ) async throws(BuildSystemError) -> TestPlan {
        guard product.isBundle else {
            return TestPlan(
                executable: product.executable.path,
                arguments: [],
                environment: environment,
                directory: root.path
            )
        }
        let helper = try await testingHelper(environment: environment)
        // Kept apart from the rest of the environment, because these are the two a command
        // reproducing this run needs and the two it is safe to write down: the tool worked
        // them out, rather than inheriting them from whoever started the run.
        var derived: [String: String] = [:]
        if let platform = await platformPath(environment: environment) {
            derived["DYLD_FRAMEWORK_PATH"] =
                platform.appending(path: "Developer/Library/Frameworks").path
            derived["DYLD_LIBRARY_PATH"] =
                platform.appending(path: "Developer/usr/lib").path
        }
        return TestPlan(
            executable: helper.path,
            arguments: [
                "--test-bundle-path", product.executable.path,
                product.executable.path,
                "--testing-library", "swift-testing",
            ],
            environment: environment.merging(derived) { _, worked in worked },
            directory: root.path,
            derived: derived
        )
    }

    /// Where the toolchain keeps the program that loads a test bundle.
    ///
    /// Derived from the toolchain this run is actually using rather than from `PATH`:
    /// `/usr/bin/swift` on macOS is a shim, and the helper lives beside the real one. The
    /// compiler is asked where its own resources are and the answer is walked up from
    /// there, so a run with a pinned toolchain finds that toolchain's helper.
    public func testingHelper(
        environment: [String: String] = [:]
    ) async throws(BuildSystemError) -> URL {
        let outcome = await runner.run(
            ProcessSpec(
                kind: .versionProbe,
                executable: executable,
                arguments: ["-print-target-info"],
                directory: root.path,
                environment: environment,
                timeout: .seconds(60)
            )
        )
        try Self.expectSuccess(outcome, doing: "swift -print-target-info", in: root.path)

        guard
            let described = try? JSONSerialization.jsonObject(
                with: Data(outcome.standardOutput)) as? [String: Any],
            let paths = described["paths"] as? [String: Any],
            let resources = paths["runtimeResourcePath"] as? String
        else {
            throw BuildSystemError(
                "`swift -print-target-info` did not say where its runtime resources are"
            )
        }
        // <toolchain>/usr/lib/swift -> <toolchain>/usr
        let helper = URL(filePath: resources)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "libexec/swift/pm/swiftpm-testing-helper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw BuildSystemError(
                """
                \(helper.path) is not there. It is the program that loads a test bundle on \
                this platform, and without it the built tests cannot be started.
                """
            )
        }
        return helper
    }

    /// Where the platform keeps `Testing.framework`, if it can be found out.
    ///
    /// Absent rather than fatal: a toolchain that needs no help finding its frameworks is
    /// a toolchain this should not be adding environment variables for.
    private func platformPath(environment: [String: String]) async -> URL? {
        let outcome = await runner.run(
            ProcessSpec(
                kind: .versionProbe,
                executable: "/usr/bin/xcrun",
                arguments: ["--show-sdk-platform-path"],
                directory: root.path,
                environment: environment,
                timeout: .seconds(60)
            )
        )
        guard outcome.exitCode == 0 else { return nil }
        let path = String(decoding: outcome.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(filePath: path)
    }

    static func expectSuccess(
        _ outcome: ProcessOutcome, doing what: String, in directory: String
    ) throws(BuildSystemError) {
        if let failure = outcome.startFailure {
            throw BuildSystemError("cannot run \(what): \(failure)")
        }
        guard outcome.exitCode == 0 else {
            let complaint = String(decoding: outcome.standardError, as: UTF8.self)
            throw BuildSystemError(
                """
                `\(what)` exited \(outcome.exitCode) in \(directory).
                \(complaint.isEmpty ? "It said nothing." : complaint)
                """
            )
        }
    }
}
