// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

public import SwiftMutantsCore
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
        timeout: Duration? = CompileDeadline.unmeasured
    ) async throws(BuildSystemError) -> TestBundles {
        try await build(scratch: scratch, environment: environment, timeout: timeout)
        let binary = try await binaryPath(scratch: scratch, environment: environment)
        var plans: [TestPlan] = []
        for product in try Self.testProducts(in: binary) {
            plans.append(try await plan(for: product, environment: environment))
        }
        return TestBundles(plans: plans)
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
                    // Warnings stay warnings, whatever the package says. A mutation is
                    // exactly the edit that produces one - a value stops being used, a
                    // result is discarded - and under `.treatAllWarnings(as: .error)` the
                    // compiler calls that an error. Here that is worse than a rejected
                    // mutant: this build is the one that produces the test bundle, so a
                    // strict package would have no run at all.
                    //
                    // The tree being built is a copy nobody ships, and what this asks is
                    // whether the program is well formed. A warning is by definition not
                    // ill-formedness.
                    "-Xswiftc", "-no-warnings-as-errors",
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
    static func testProducts(in binary: URL) throws(BuildSystemError) -> [TestProduct] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: binary.path)
        } catch {
            throw BuildSystemError("\(binary.path) could not be read: \(error)")
        }
        let bundles = names.filter { $0.hasSuffix(".xctest") }.sorted()
        guard !bundles.isEmpty else {
            throw BuildSystemError(
                """
                no test bundle in \(binary.path). The package built, so this means it \
                declares no test target - there is nothing for a mutant to be caught by.
                """
            )
        }
        // All of them. This took the first and refused the rest - "swift-mutants runs one,
        // and picking would be picking for you" - which was true while SwiftPM built one
        // bundle for a whole package. Its build system builds one per test target, thirty
        // of them here, so the refusal became a refusal to measure anything at all.
        return bundles.map { Self.product(named: $0, in: binary) }
    }

    /// One bundle, and how to start what is inside it.
    private static func product(named name: String, in binary: URL) -> TestProduct {
        let bundle = binary.appending(path: name)
        let stem = String(name.dropLast(".xctest".count))
        let isBundle =
            (try? bundle.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isBundle == true else {
            return TestProduct(executable: bundle, isBundle: false, module: stem)
        }
        return TestProduct(
            executable: bundle.appending(path: "Contents/MacOS/\(stem)"),
            isBundle: true,
            module: stem
        )
    }

    /// The built tests, and whether they can be started directly.
    struct TestProduct {
        let executable: URL
        let isBundle: Bool

        /// The test target it was built from, which is the name its tests wear.
        let module: String
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
                directory: root.path,
                module: product.module
            )
        }
        let helper = try await testingHelper(environment: environment)
        // Kept apart from the rest of the environment, because these are the two a command
        // reproducing this run needs and the two it is safe to write down: the tool worked
        // them out, rather than inheriting them from whoever started the run.
        let derived = await frameworkPaths(environment: environment)
        return TestPlan(
            executable: helper.path,
            arguments: [
                "--test-bundle-path", product.executable.path,
                product.executable.path,
                "--testing-library", "swift-testing",
            ],
            environment: environment.merging(derived) { _, worked in worked },
            directory: root.path,
            derived: derived,
            module: product.module
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

    /// Where this toolchain keeps `Testing.framework`, and the libraries beside it.
    ///
    /// A test bundle is a dylib linked against `@rpath/Testing.framework`, so a process
    /// that loads one without this fails with `Library not loaded` - which reads as a bug
    /// in the package rather than as a variable nobody set.
    ///
    /// Two layouts, and the difference is not cosmetic. A full Xcode keeps them under the
    /// SDK's platform directory; a Command Line Tools installation has no platform
    /// directory at all - `xcrun --show-sdk-platform-path` fails outright - and keeps them
    /// under the developer directory instead. Asked of the filesystem rather than decided
    /// from which tool answered, because the question is where the framework is and the
    /// filesystem is what knows.
    ///
    /// Empty rather than fatal when neither holds it: a toolchain that needs no help
    /// finding its own frameworks is one this should not be setting variables for, and a
    /// guess would be a variable pointing somewhere that does not exist.
    private func frameworkPaths(environment: [String: String]) async -> [String: String] {
        // Two layouts, and they agree on less than they look like they do. Xcode keeps the
        // frameworks at `<platform>/Developer/Library/Frameworks`; the Command Line Tools
        // keep them at `<installation>/Library/Developer/Frameworks` - one segment apart,
        // and a unification that assumed otherwise was contradicted by the filesystem.
        //
        // Both paths of a pair are needed together: `Testing.framework` is itself linked
        // against `lib_TestingInterop.dylib` beside it, so finding the framework without
        // the library loads nothing and says so in a sentence about neither.
        var candidates: [(frameworks: URL, libraries: URL)] = []
        if let platform = await platformPath(environment: environment) {
            let root = platform.appending(path: "Developer")
            candidates.append(
                (root.appending(path: "Library/Frameworks"), root.appending(path: "usr/lib")))
        }
        if let developer = await developerPath(environment: environment) {
            let root = developer.appending(path: "Library/Developer")
            candidates.append(
                (root.appending(path: "Frameworks"), root.appending(path: "usr/lib")))
        }
        for candidate in candidates
        where FileManager.default.fileExists(
            atPath: candidate.frameworks.appending(path: "Testing.framework").path)
        {
            return [
                "DYLD_FRAMEWORK_PATH": candidate.frameworks.path,
                "DYLD_LIBRARY_PATH": candidate.libraries.path,
            ]
        }
        return [:]
    }

    /// The developer directory this run's toolchain belongs to, if it has one.
    ///
    /// Walked up from the compiler's own runtime resources rather than read from
    /// `xcode-select`, for the same reason the helper is: a run with a pinned toolchain has
    /// to find that toolchain's frameworks and not whichever one is selected globally.
    private func developerPath(environment: [String: String]) async -> URL? {
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
        guard outcome.exitCode == 0,
            let described = try? JSONSerialization.jsonObject(
                with: Data(outcome.standardOutput)) as? [String: Any],
            let paths = described["paths"] as? [String: Any],
            let resources = paths["runtimeResourcePath"] as? String
        else {
            return nil
        }
        // <developer>/usr/lib/swift -> <developer>
        return URL(filePath: resources)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Where the platform keeps `Testing.framework`, if there is a platform.
    ///
    /// Absent rather than fatal: a Command Line Tools installation has no platform
    /// directory, and `xcrun` says so by failing.
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
