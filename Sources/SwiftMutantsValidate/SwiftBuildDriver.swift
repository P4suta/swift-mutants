// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import SwiftMutantsRunner

/// Asks SwiftPM to build a package, and reports what the compiler said.
///
/// The driver validation actually uses, and the reason is module structure. A package is
/// not a pile of files: each target compiles on its own, against its own dependencies, with
/// its own search paths and its own language mode. Handing every source file in a package
/// to one `swiftc -typecheck` compiles none of them - the imports resolve to nothing and
/// the errors are about the arrangement rather than about any mutant. Measured on this
/// repository: 57 files, and the first one reported as not compiling with no mutants in it
/// at all.
///
/// So SwiftPM plans the build, because SwiftPM is the thing that knows how. The cost is a
/// build rather than a typecheck, and it is not an extra cost: a run has to build the
/// instrumented tree anyway, and this is that build. A round that finds rejections is
/// followed by an incremental rebuild of what changed, not a fresh one.
public struct SwiftBuildDriver: TypecheckDriver {

    private let runner: Runner
    private let executable: String
    private let root: String
    private let scratch: String
    private let environment: [String: String]
    private let timeout: Duration?

    /// Prepares to build the package at `root` into `scratch`.
    public init(
        runner: Runner,
        executable: String = "/usr/bin/swift",
        root: String,
        scratch: String,
        environment: [String: String] = [:],
        timeout: Duration? = .seconds(1800)
    ) {
        self.runner = runner
        self.executable = executable
        self.root = root
        self.scratch = scratch
        self.environment = environment
        self.timeout = timeout
    }

    /// Builds the package, ignoring the paths it is handed.
    ///
    /// The paths are already in the tree - validation wrote them there - and a build is
    /// about a package rather than about a list of files. They are accepted and ignored
    /// rather than refused, because the protocol is what lets a test put a scripted
    /// compiler in this place.
    public func typecheck(_ paths: [String]) async -> CompilerOutput {
        let outcome = await runner.run(
            ProcessSpec(
                kind: .build,
                executable: executable,
                arguments: [
                    "build", "--build-tests", "--scratch-path", scratch,
                    "-Xswiftc", "-diagnostic-style=llvm",
                    // Report every error in a module rather than stopping at the first.
                    // Each round of validation is a build, so a round that surfaces one
                    // error costs the same as a round that surfaces forty - and the loop
                    // then needs forty times as many of them.
                    "-Xswiftc", "-continue-building-after-errors",
                ],
                directory: root,
                environment: environment,
                timeout: timeout
            )
        )
        let said =
            String(decoding: outcome.standardError, as: UTF8.self)
            + String(decoding: outcome.standardOutput, as: UTF8.self)
        return CompilerOutput(exitCode: Int32(truncatingIfNeeded: outcome.exitCode), text: said)
    }
}
