// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import SwiftMutantsBuild
public import SwiftMutantsRunner

/// Asks each module on its own, all at once.
///
/// `swift build` cannot report an error in a module whose dependency failed to build -
/// there is nothing to build it against - so a package twenty module layers deep needs
/// twenty builds to surface twenty rejections, each of them a build of the whole package.
/// Dogfooding this package took nineteen, and every one of them compiled the same modules
/// again to reach one layer further down.
///
/// Asked per module against the modules a pristine build already produced, every module
/// answers at once and answers independently: a broken dependency silences nothing, because
/// nothing is reading the dependency's source. The number of compiles stops following the
/// depth of somebody's package and becomes one pass over its breadth, which is also the
/// shape that parallelises.
///
/// Two things make it sound. The modules are compiled from the plan SwiftPM wrote rather
/// than from arguments assembled here, so nothing is guessed; and a file that belongs to no
/// module in that plan sends the whole question to a real build, because a plan that does
/// not describe the tree is exactly the situation where being clever rejects mutants at
/// positions nobody reported.
public struct ModuleTypecheckDriver: TypecheckDriver {

    private let runner: Runner
    private let manifest: BuildManifest
    private let root: String
    private let environment: [String: String]
    private let timeout: Duration?
    private let fallback: any TypecheckDriver

    /// Prepares to ask each module of `manifest`, falling back to `fallback` when it cannot.
    public init(
        runner: Runner,
        manifest: BuildManifest,
        root: String,
        environment: [String: String] = [:],
        timeout: Duration? = .seconds(1800),
        fallback: any TypecheckDriver
    ) {
        self.runner = runner
        self.manifest = manifest
        self.root = root
        self.environment = environment
        self.timeout = timeout
        self.fallback = fallback
    }

    /// Asks every module that holds one of `paths` whether it is still well-typed.
    public func typecheck(_ paths: [String]) async -> CompilerOutput {
        guard let wanted = Self.modules(of: manifest, holding: paths) else {
            return await fallback.typecheck(paths)
        }
        guard !wanted.isEmpty else { return CompilerOutput(exitCode: 0, text: "") }

        return await withTaskGroup(of: CompilerOutput.self) { group in
            for module in wanted {
                group.addTask { await ask(module) }
            }
            var said: [CompilerOutput] = []
            for await one in group { said.append(one) }
            return Self.merged(said)
        }
    }

    /// One module's answer.
    private func ask(_ module: BuildManifest.Module) async -> CompilerOutput {
        let arguments = module.typecheckArguments
        guard let executable = arguments.first else {
            return CompilerOutput(
                exitCode: 1, text: "the plan for \(module.name) names no compiler to run")
        }
        let outcome = await runner.run(
            ProcessSpec(
                kind: .typecheck,
                executable: executable,
                arguments: Array(arguments.dropFirst()),
                directory: root,
                environment: environment,
                timeout: timeout
            )
        )
        return CompilerOutput(
            exitCode: Int32(truncatingIfNeeded: outcome.exitCode),
            text: String(decoding: outcome.standardError, as: UTF8.self)
                + String(decoding: outcome.standardOutput, as: UTF8.self)
        )
    }

    /// The modules holding these files, or nothing if any file belongs to none of them.
    ///
    /// Only the modules that changed. The rest of the package compiled a moment ago, and no
    /// mutant elsewhere can have changed that: a mutant is an expression, and the private
    /// guard around it is not part of any module's interface.
    ///
    /// `nil` rather than a smaller list when a file is a stranger. A file this tool wrote
    /// that the plan does not mention means the plan is not describing this tree, and
    /// answering anyway would be answering about a different program.
    static func modules(
        of manifest: BuildManifest, holding paths: [String]
    ) -> [BuildManifest.Module]? {
        var owner: [String: Int] = [:]
        for (position, module) in manifest.modules.enumerated() {
            for source in module.sources { owner[Self.settled(source)] = position }
        }

        var wanted: Set<Int> = []
        for path in paths {
            guard let position = owner[Self.settled(path)] else { return nil }
            wanted.insert(position)
        }
        return manifest.modules.enumerated()
            .filter { wanted.contains($0.offset) }
            .map(\.element)
    }

    /// A path with every symlink in it followed.
    ///
    /// A snapshot under `/var` is the same tree as one under `/private/var`, and macOS hands
    /// out both spellings for it. Comparing the strings alone once made every diagnostic in
    /// a run belong to no file at all, and the run then explained nothing about anything.
    private static func settled(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().path
    }

    /// Several modules' answers as one.
    ///
    /// Every module's diagnostics, not the first module's: keeping one would put this
    /// straight back to a round per module layer, which is the thing it replaces. The tree
    /// is accepted only when every module accepted it, and a tree nobody asked about is a
    /// tree the last compile already accepted.
    static func merged(_ said: [CompilerOutput]) -> CompilerOutput {
        CompilerOutput(
            exitCode: said.first { $0.exitCode != 0 }?.exitCode ?? 0,
            text: said.map(\.text).joined()
        )
    }
}
