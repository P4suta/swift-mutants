// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsInstrument
import SwiftMutantsRunner
import SwiftMutantsTCE
import SwiftMutantsValidate

/// Asking the compiler which survivors could never have been caught.
///
/// A survivor is either a hole in somebody's tests or a mutant that should never have been
/// made. The second kind cannot be caught by anything, ever - `x * 1` and `x` are the same
/// instruction sequence - and reporting it tells somebody to go and look for a hole that is
/// not there. That is the most expensive way a mutation tool can be wrong, because the time
/// it costs is a person's rather than a machine's.
///
/// Only survivors, and only when asked. It costs one compile of one module per survivor,
/// which is worth it for an answer that no amount of test-writing would ever change, and is
/// not worth doing to a mutant a test already caught.
extension Run {

    /// Which survivors the compiler proves are the original program, or another mutant.
    ///
    /// Nothing when it was not asked for, when there is no plan to compile from, or when
    /// the original's own fingerprint could not be taken - there is nothing to compare
    /// against then, and a comparison against nothing would call everything equivalent.
    func equivalence(
        among results: [MutantResult],
        _ work: Work,
        at site: Site,
        progress: @Sendable (RunStage) -> Void
    ) async -> Equivalence? {
        guard configuration.execution.provesEquivalence, let manifest = site.plan else {
            return nil
        }
        let tree = site.tree
        let survivors = Set(
            results.filter { $0.verdict.outcome == .survived }.map(\.identity))
        guard !survivors.isEmpty else { return nil }

        let wanted = work.validated.files.enumerated().flatMap { position, file in
            file.instrumented.mutants
                .filter { survivors.contains($0.identity) }
                .map { (file: position, mutant: $0) }
        }
        guard !wanted.isEmpty else { return nil }
        progress(.provingEquivalence(survivors: wanted.count))

        let lowering = Lowering(
            runner: runner,
            manifest: manifest,
            root: tree.path,
            cache: Self.buildDirectory(in: tree).appending(path: "EquivalenceModuleCache").path,
            environment: site.environment
        )
        guard
            let original = await lowering.fingerprint(
                of: work, file: wanted[0].file, applying: nil, in: tree)
        else {
            return nil
        }

        var fingerprints: [UInt32: Digest] = [:]
        for entry in wanted {
            guard
                let found = await lowering.fingerprint(
                    of: work, file: entry.file, applying: entry.mutant, in: tree)
            else {
                continue
            }
            fingerprints[entry.mutant.index] = found
        }
        return Equivalence(of: fingerprints, matching: original)
    }
}

/// Compiling one file with one mutant in it, and hashing what comes out.
///
/// The instrumented tree cannot answer this: every mutant is in it at once, behind a guard
/// the optimiser cannot see through, so its lowered form holds both branches of everything.
/// The question is about one mutant alone, so one mutant alone is what is written - into the
/// tree, compiled, and put back.
struct Lowering: Sendable {

    let runner: Runner
    let manifest: BuildManifest
    let root: String
    let cache: String
    let environment: [String: String]

    /// The fingerprint of one file with one mutant applied, or with none.
    ///
    /// Nothing when the module cannot be found or the compiler would not produce anything.
    /// A fingerprint nobody could take is a mutant this says nothing about, which is the
    /// right answer: it stays a survivor.
    func fingerprint(
        of work: Work, file position: Int, applying mutant: InstrumentedMutant?, in tree: URL
    ) async -> Digest? {
        guard work.subjects.indices.contains(position) else { return nil }
        let subject = work.subjects[position]
        let path = tree.appending(path: subject.name)
        guard let instrumented = try? String(contentsOf: path, encoding: .utf8) else { return nil }

        let written = mutant.map { Self.applying($0, to: subject.source) } ?? subject.source
        guard (try? Data(written.utf8).write(to: path)) != nil else { return nil }
        defer { try? Data(instrumented.utf8).write(to: path) }

        guard let module = Self.module(of: path.path, in: manifest) else { return nil }
        let arguments = module.loweringArguments(cachingModulesIn: cache)
        guard let executable = arguments.first else { return nil }

        let outcome = await runner.run(
            ProcessSpec(
                kind: .typecheck,
                executable: executable,
                arguments: Array(arguments.dropFirst()),
                directory: root,
                environment: environment,
                timeout: .seconds(600)
            )
        )
        guard outcome.exitCode == 0 else { return nil }
        return Fingerprint.of(String(decoding: outcome.standardOutput, as: UTF8.self))
    }

    /// The original file with one mutant's bytes in it, and nothing else changed.
    static func applying(_ mutant: InstrumentedMutant, to source: String) -> String {
        let bytes = Array(source.utf8)
        guard mutant.span.end <= bytes.count else { return source }
        return String(decoding: bytes[0..<mutant.span.start], as: UTF8.self)
            + mutant.replacement
            + String(decoding: bytes[mutant.span.end...], as: UTF8.self)
    }

    /// The module a file belongs to.
    static func module(of path: String, in manifest: BuildManifest) -> BuildManifest.Module? {
        let settled = URL(filePath: path).resolvingSymlinksInPath().path
        return manifest.modules.first {
            $0.sources.contains { URL(filePath: $0).resolvingSymlinksInPath().path == settled }
        }
    }
}
