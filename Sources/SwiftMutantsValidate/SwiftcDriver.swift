// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import SwiftMutantsRunner

/// Asks the real Swift compiler whether a tree is well-typed.
///
/// `-typecheck` rather than a build: validation only needs to know whether the compiler
/// accepts the tree, and skipping code generation is the difference between a question
/// asked once per round and a question that costs what a build costs. The work is bounded
/// by the size of the files rather than by anything downstream of them.
///
/// `-diagnostic-style=llvm` because that is the form ``CompilerDiagnostic`` reads:
/// `path:line:column: severity: message`, one per line, with the source excerpt and caret
/// around it. The alternative style boxes diagnostics in drawing characters.
public struct SwiftcDriver: TypecheckDriver {

    private let runner: Runner
    private let executable: String
    private let extraArguments: [String]
    private let directory: String
    private let environment: [String: String]
    private let timeout: Duration?

    /// Prepares to typecheck with a particular compiler.
    ///
    /// `extraArguments` is whatever the package needs to be understood - search paths, a
    /// language mode, a target triple. They are passed through verbatim and never parsed:
    /// a tool that interpreted build flags would be a second, worse build system.
    public init(
        runner: Runner,
        executable: String = "/usr/bin/swiftc",
        extraArguments: [String] = [],
        directory: String,
        environment: [String: String] = [:],
        timeout: Duration? = .seconds(300)
    ) {
        self.runner = runner
        self.executable = executable
        self.extraArguments = extraArguments
        self.directory = directory
        self.environment = environment
        self.timeout = timeout
    }

    /// Typechecks these files.
    public func typecheck(_ paths: [String]) async -> CompilerOutput {
        let outcome = await runner.run(
            ProcessSpec(
                kind: .typecheck,
                executable: executable,
                arguments: ["-typecheck", "-diagnostic-style=llvm"] + extraArguments + paths,
                directory: directory,
                environment: environment,
                timeout: timeout
            )
        )
        // Both streams, because a diagnostic is a diagnostic whichever one it came out of
        // and the parser reads whole lines rather than depending on their order.
        let said =
            String(decoding: outcome.standardError, as: UTF8.self)
            + String(decoding: outcome.standardOutput, as: UTF8.self)
        return CompilerOutput(
            exitCode: Int32(truncatingIfNeeded: outcome.exitCode),
            text: said,
            milliseconds: outcome.durationMilliseconds
        )
    }
}
