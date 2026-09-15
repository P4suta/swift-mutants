// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public import SwiftMutantsBuild
public import SwiftMutantsCore
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
/// A few at a time, not all at once. The pass is as wide as `jobs` allows, because a
/// compiler is the most memory-hungry thing this tool starts and a package of fifty modules
/// would otherwise start fifty of them.
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
    private let cache: String?
    private let environment: [String: String]
    private let timeout: Duration?
    private let jobs: Int
    private let fallback: any TypecheckDriver

    /// Prepares to ask each module of `manifest`, falling back to `fallback` when it cannot.
    public init(
        runner: Runner,
        manifest: BuildManifest,
        root: String,
        cachingModulesIn cache: String? = nil,
        environment: [String: String] = [:],
        timeout: Duration? = CompileDeadline.unmeasured,
        jobs: Int = 4,
        fallback: any TypecheckDriver
    ) {
        self.runner = runner
        self.manifest = manifest
        self.root = root
        self.cache = cache
        self.environment = environment
        self.timeout = timeout
        self.jobs = max(1, jobs)
        self.fallback = fallback
    }

    /// Asks every module that holds one of `paths` whether it is still well-typed.
    public func typecheck(_ paths: [String]) async -> CompilerOutput {
        guard let wanted = Self.modules(of: manifest, holding: paths) else {
            return await fallback.typecheck(paths)
        }
        guard !wanted.isEmpty else { return CompilerOutput(exitCode: 0, text: "") }

        // A few at a time rather than all of them. One compile per module is what turned a
        // compile per module *layer* into one pass over a package's breadth, and that is
        // the right shape - but a pass with nothing bounding it starts a compiler per
        // module, and a compiler is the most memory-hungry thing this tool runs. Fifty at
        // once on one machine is not parallelism; it is a machine that swaps, and the run
        // that was supposed to be faster than the serial one ends up slower than it with
        // nothing in the output to say why.
        //
        // `jobs` because it is already the number that says how many processes this tool
        // may have running, and a second knob for the same question is a knob somebody
        // sets once and never reconciles with the first.
        return Self.merged(
            await WorkerPool(jobs: jobs).run(over: wanted) { module, _ in await ask(module) })
    }

    /// One module's answer.
    private func ask(_ module: BuildManifest.Module) async -> CompilerOutput {
        let arguments = module.diagnosingArguments(cachingModulesIn: cache)
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
                + String(decoding: outcome.standardOutput, as: UTF8.self),
            milliseconds: outcome.durationMilliseconds
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
            text: said.map(\.text).joined(),
            // The longest of them, because the modules were asked at once: a round of this
            // costs what its slowest module cost, not what all of them cost added up.
            milliseconds: said.compactMap(\.milliseconds).max()
        )
    }
}
