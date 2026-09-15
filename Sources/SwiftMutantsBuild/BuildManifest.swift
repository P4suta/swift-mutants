// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// The build SwiftPM planned, read rather than guessed at.
///
/// Validation asks one question - would the compiler accept this tree - and the honest way
/// to ask it is per module. A package is not a pile of files: each target compiles against
/// its own dependencies, with its own search paths, module maps, language mode and upcoming
/// features. Forty-odd arguments per target on this package alone, and every one of them a
/// chance to be right here and wrong on somebody else's.
///
/// SwiftPM has already worked them out. It writes the plan as an llbuild manifest holding,
/// for every module, the exact `swiftc` invocation it would run. This reads that.
///
/// Reading it is what makes validation one pass instead of one per module layer. `swift
/// build` cannot report an error in a module whose dependency failed to build, because
/// there is nothing to build it against - so a package twenty modules deep needs twenty
/// builds to surface twenty rejections, each of them a build of the whole package. Asked
/// per module against the modules a pristine build already produced, every module answers
/// at once and answers independently: a broken dependency does not silence anything,
/// because nothing is reading the dependency's source.
///
/// The format is SwiftPM's own and carries no promise of stability. That is why a manifest
/// this cannot read is `nil` rather than an error: the caller builds the whole package
/// instead, which is slower and always works. Guessing at a shape that has changed is the
/// one outcome worse than being slow.
public struct BuildManifest: Sendable, Hashable {

    /// One Swift module, and the command that compiles it.
    public struct Module: Sendable, Hashable {

        /// What the module is called.
        public let name: String

        /// The compiler and every argument SwiftPM would give it.
        public let arguments: [String]

        /// The Swift files it compiles, as absolute paths.
        ///
        /// Read from the command's inputs rather than from its arguments, where the sources
        /// arrive as a response file. What they are for is deciding which modules a set of
        /// instrumented files touches: the rest of the package is unchanged and asking
        /// about it would be asking a question whose answer is already known.
        public let sources: [String]

        /// Records a module's compile command.
        public init(name: String, arguments: [String], sources: [String] = []) {
            self.name = name
            self.arguments = arguments
            self.sources = sources
        }

        /// Arguments that make the compiler diagnose this module and write nothing.
        ///
        /// The same command minus everything that produces a file. Validation reads none of
        /// an object, a module, a header, a dependency file or an index, and each of them
        /// would have this writing into a tree it is only asking about - including over the
        /// modules the next question needs to be answered against.
        ///
        /// `-emit-sil` rather than `-typecheck`, and the difference is not an optimisation.
        /// A whole class of Swift error is found after type checking, while the compiler is
        /// lowering the program: `missing return in instance method expected to return`,
        /// use before initialisation, and the rest of the mandatory dataflow passes.
        /// `-typecheck` accepts a function with a missing return and says nothing.
        /// Measured on this package: a `return-replacement` mutant left a method with no
        /// return on one path, `-typecheck` exited zero, and the build that followed
        /// validation failed - after validation had already said the tree was fine, which
        /// is the worst place for a tool to be wrong.
        ///
        /// The output goes to `/dev/null`, so this still writes nothing. `-emit-sil` stops
        /// before instruction selection, so it is a fraction of the compile it replaces -
        /// and, unlike the build, it can be asked about one module at a time.
        public var diagnosingArguments: [String] { diagnosingArguments(cachingModulesIn: nil) }

        /// The same, caching compiled modules in `cache` rather than where the build does.
        ///
        /// Clang caches compiled module files, and the compiler refuses a cache holding one
        /// module under two names - which is what happens when a build and a typecheck of
        /// the same tree disagree about how to spell a path, as `/var` and `/private/var`
        /// do on macOS for the same directory. The build then fails with `module
        /// '_DarwinFoundation1' is defined in both`, which is about neither the package nor
        /// any mutant in it, and which arrives after validation has already said the tree
        /// was fine.
        ///
        /// A question must not write into the answer.
        public func diagnosingArguments(cachingModulesIn cache: String?) -> [String] {
            var asked: [String] = []
            var index = arguments.startIndex
            while index < arguments.endIndex {
                let argument = arguments[index]
                // `-Xcc -g` is two words that travel together. Dropping the second leaves a
                // bare `-Xcc` that swallows whatever follows, and the compiler reports it as
                // an unexpected input file - a complaint about nothing in the package,
                // arriving where this tool is deciding what the package refused.
                if Self.carriesTheNextArgument.contains(argument),
                    arguments.index(after: index) < arguments.endIndex
                {
                    asked.append(argument)
                    asked.append(arguments[arguments.index(after: index)])
                    index = arguments.index(index, offsetBy: 2)
                    continue
                }
                if Self.writesAFile.contains(argument) {
                    index = arguments.index(after: index)
                    continue
                }
                if Self.writesAFileNamedNext.contains(argument) {
                    index =
                        arguments.index(
                            index, offsetBy: 2, limitedBy: arguments.endIndex) ?? arguments.endIndex
                    continue
                }
                asked.append(argument)
                index = arguments.index(after: index)
            }
            if let cache { asked += ["-module-cache-path", cache] }
            // After the compiler, which runs the program and stays the first word. Whole
            // module because a module lowered a file at a time writes a file per file, and
            // there is one place here to throw output away.
            asked.insert(
                contentsOf: [
                    "-emit-sil", "-wmo", "-o", "/dev/null", "-diagnostic-style=llvm",
                ],
                at: min(1, asked.count)
            )

            // Last, because the compiler takes the last word on the subject and the
            // package's own flag is somewhere in the middle of its plan.
            //
            // A mutation is exactly the edit that produces a warning: `a + b` becomes `a`,
            // and a value stops being used. Under `.treatAllWarnings(as: .error)` the
            // compiler then calls that an error, and a mutant that is a perfectly good
            // question about somebody's tests comes back rejected - so it leaves the
            // denominator, and the score of a strict package goes *up* because it is
            // strict. The flattering direction, arrived at silently.
            //
            // What this compile asks is whether the mutant is a well-formed program, and a
            // warning is by definition not ill-formedness. The mutant lives in a copy
            // nobody ships, so nothing about the package's own build changes: this is a
            // question, and a question must not write into the answer.
            asked.append("-no-warnings-as-errors")
            return asked
        }

        /// Flags whose next word belongs to them whatever it looks like.
        private static let carriesTheNextArgument: Set<String> = [
            "-Xcc", "-Xfrontend", "-Xllvm", "-Xclang-linker", "-Xswiftc",
        ]

        /// Arguments that make the compiler lower this module and print the result.
        ///
        /// The same question as ``diagnosingArguments(cachingModulesIn:)`` with the answer
        /// kept: optimised, so that a change which makes no difference to the program makes
        /// no difference to the text, and printed rather than thrown away, because the text
        /// is the thing being compared.
        public func loweringArguments(cachingModulesIn cache: String?) -> [String] {
            // The plan's own optimisation level has to go, not merely be overridden. A
            // debug build carries `-Onone`, it arrives after anything inserted at the
            // front, and the last one wins - so the compiler would be asked to optimise
            // and told not to, and every mutant would look like a change to the program.
            diagnosingArguments(cachingModulesIn: cache)
                .filter { !Self.optimisation.contains($0) }
                .map { $0 == "/dev/null" ? "-" : $0 }
                + ["-O"]
        }

        /// Every spelling of "how hard to optimise".
        private static let optimisation: Set<String> = [
            "-Onone", "-O", "-Osize", "-Ounchecked", "-Oplayground",
        ]

        /// Flags that produce a file and take no argument.
        private static let writesAFile: Set<String> = [
            "-c", "-emit-module", "-emit-dependencies", "-emit-objc-header",
            "-serialize-diagnostics", "-parseable-output", "-incremental",
            "-enable-batch-mode", "-whole-module-optimization",
            // Constant extraction derives its output path from `-o`, so a question sent to
            // `/dev/null` asks the compiler to open `/dev/Core.swiftconstvalues` - which
            // nobody may write, and the refusal arrives as `Operation not permitted` in
            // the middle of deciding what the package refused.
            "-emit-const-values", "-save-temps",
        ]

        /// Flags that produce a file named by the word after them.
        private static let writesAFileNamedNext: Set<String> = [
            "-o", "-emit-module-path", "-emit-objc-header-path", "-output-file-map",
            "-index-store-path", "-emit-dependencies-path", "-serialize-diagnostics-path",
            "-module-cache-path",
            // The list constant extraction reads, which means nothing once the extraction
            // itself is gone, and a bare path left behind is an input file the compiler
            // complains about.
            "-const-gather-protocols-list", "-const-gather-protocols-file",
            "-dependency-scan-serialize-diagnostics-path",
        ]
    }

    /// Every Swift module in the plan, in the order the manifest names them.
    public let modules: [Module]

    /// Records a plan directly, for a caller that has one already.
    public init(modules: [Module]) {
        self.modules = modules
    }

    /// Reads a manifest, or refuses one it does not recognise.
    ///
    /// Line-oriented, over a file a program wrote: each command is a key at one indent and
    /// its `args` is a JSON array on one line. A manifest with no Swift module commands in
    /// it at all is refused rather than returned empty, because an empty plan and a plan
    /// this cannot read look the same to a caller and mean opposite things.
    public init?(parsing text: String) {
        var found: [Module] = []
        var name: String?
        var sources: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let opened = Self.moduleName(ofCommand: line) {
                name = opened
                sources = []
                continue
            }
            guard name != nil else { continue }
            if let inputs = Self.list(named: "inputs", in: line) {
                sources = inputs.filter { $0.hasSuffix(".swift") }
                continue
            }
            guard let open = name, let arguments = Self.list(named: "args", in: line) else {
                continue
            }
            found.append(Module(name: open, arguments: arguments, sources: sources))
            name = nil
        }
        guard !found.isEmpty else { return nil }
        self.modules = found
    }

    /// The module a command compiles, if it compiles one.
    ///
    /// `"C.<Module>-<triple>-<configuration>.module":` and nothing else. The same file holds
    /// linking, copying, C compilation and test discovery, none of which is a question about
    /// whether Swift accepts a tree.
    private static func moduleName(ofCommand line: Substring) -> String? {
        let key = line.drop { $0 == " " }
        guard line.count - key.count == 2, key.hasPrefix("\"C."), key.hasSuffix(".module\":")
        else {
            return nil
        }
        return Self.nameBeforeTriple(key.dropFirst(3).dropLast(".module\":".count))
    }

    /// The module name in `<Module>-<arch>-<vendor>-<os>-<configuration>`.
    ///
    /// Counted from the end rather than matched from the front, because a module may hold
    /// hyphens and a triple always holds exactly four of them here.
    private static func nameBeforeTriple(_ inside: Substring) -> String? {
        let parts = inside.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count > Self.partsAfterTheName else { return nil }
        let name = parts.dropLast(Self.partsAfterTheName).joined(separator: "-")
        return name.isEmpty ? nil : name
    }

    /// `arm64`, `apple`, `macosx`, `debug`: what follows a module's name in a command key.
    private static let partsAfterTheName = 4

    /// The list on a `<name>:` line holding a JSON array, if this is one.
    private static func list(named field: String, in line: Substring) -> [String]? {
        let trimmed = line.drop { $0 == " " }
        guard trimmed.hasPrefix("\(field):") else { return nil }
        let json = trimmed.dropFirst(field.count + 1).drop { $0 == " " }
        guard let data = json.data(using: .utf8),
            let list = try? JSONDecoder().decode([String].self, from: data),
            !list.isEmpty
        else {
            return nil
        }
        return list
    }
}
