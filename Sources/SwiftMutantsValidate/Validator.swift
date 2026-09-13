// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument

/// Works out which mutants the compiler will accept.
///
/// The loop is: instrument everything, ask once, drop what was refused, ask again. It ends
/// because every round that finds a rejection removes at least one candidate, so it cannot
/// run more times than there are candidates - and in practice it ends after two compiles,
/// one that finds every rejection at once and one that confirms what is left.
///
/// That is the whole reason ``InstrumentedMutant/instrumentedSpan`` exists. `swiftc`
/// reports every error in a file rather than stopping at the first, and points `line:col`
/// at the operator inside the branch that broke, so one compile names every refusal.
/// Bisection - a compile per halving - is the fallback for a compile that will not say
/// where it hurts, not the mechanism.
///
/// A compile that explains only some of what it is unhappy about is still worth acting on.
/// Dropping the mutants it did place is cheaper than halving for all of them, and it often
/// removes the cause of the errors it did not place. Only a compile that fails while
/// naming nothing this tool put there falls through to halving, and a rejection found that
/// way carries no diagnostics - because there were none to carry, not because they were
/// discarded.
public struct Validator: Sendable {

    private let compiler: any TypecheckDriver
    private let directory: URL

    /// Prepares to validate into `directory`, which is written to and nothing else is.
    public init(compiler: any TypecheckDriver, directory: URL) {
        self.compiler = compiler
        self.directory = directory
    }

    /// Narrows each file to the mutants the compiler accepts.
    public func validate(
        _ files: [FileUnderValidation]
    ) async throws(ValidationError) -> Validation {
        var discoveries = files.map(\.discovery)
        var rejected: [Rejection] = []
        var rounds = 0
        var bisected = false

        // At most one round per candidate, because a round that changes nothing ends the
        // loop and a round that changes something removes a candidate.
        let ceiling = discoveries.reduce(1) { $0 + $1.candidates.count }
        while rounds < ceiling {
            rounds += 1
            let instrumented = try Self.instrument(files, as: discoveries)
            let paths = try write(instrumented, for: files)
            let output = await compiler.typecheck(paths)
            guard output.exitCode != 0 else {
                return Validation(
                    files: zip(paths, instrumented).map {
                        ValidatedFile(path: $0, instrumented: $1)
                    },
                    rejected: rejected,
                    rounds: rounds,
                    bisected: bisected
                )
            }

            let attribution = Attribute.diagnostics(
                CompilerDiagnostic.parse(output.text),
                to: Dictionary(uniqueKeysWithValues: zip(paths, instrumented))
            )
            if !attribution.rejected.isEmpty {
                // Act on what the compiler explained, even when it did not explain
                // everything. Dropping the placed refusals first is strictly cheaper than
                // halving for all of them, and it often removes the cause of the errors
                // that could not be placed - a compile the loop then does not have to
                // spend. Whatever is still wrong comes back on the next round with a
                // smaller catalogue behind it.
                rejected += attribution.rejected
                let refused = Set(attribution.rejected.map { Key($0.span, $0.rule) })
                discoveries = discoveries.map { discovery in
                    discovery.keeping { !refused.contains(Key($0.span, $0.rule)) }
                }
                continue
            }

            // The compile failed while naming nothing this tool put there. Guessing from
            // here is how a tool starts rejecting mutants at positions nobody reported, so
            // it stops guessing and pays for halving instead.
            bisected = true
            let found = try await bisect(files, discoveries: discoveries)
            rejected += found.rejected
            discoveries = found.discoveries
            let confirmed = try await confirm(files, discoveries: discoveries)
            return Validation(
                files: confirmed.files,
                rejected: rejected,
                rounds: rounds + found.rounds + confirmed.rounds,
                bisected: bisected
            )
        }
        throw ValidationError(
            """
            validation did not settle after \(rounds) compiles. Each round should remove at \
            least one mutant, so this means the compiler refused the same tree twice.
            """
        )
    }

    /// What identifies a candidate inside one file: the bytes it edits and the rule.
    private struct Key: Hashable {
        let span: SourceSpan
        let rule: RuleIdentifier
        init(_ span: SourceSpan, _ rule: RuleIdentifier) {
            self.span = span
            self.rule = rule
        }
    }

    // MARK: - Rounds

    private static func instrument(
        _ files: [FileUnderValidation], as discoveries: [FileDiscovery]
    ) throws(ValidationError) -> [InstrumentedFile] {
        var instrumented: [InstrumentedFile] = []
        for (file, discovery) in zip(files, discoveries) {
            do {
                instrumented.append(try Instrument.file(file.source, discovery: discovery))
            } catch {
                throw ValidationError("\(file.name) could not be instrumented: \(error)")
            }
        }
        return instrumented
    }

    private func write(
        _ instrumented: [InstrumentedFile], for files: [FileUnderValidation]
    ) throws(ValidationError) -> [String] {
        var paths: [String] = []
        for (file, built) in zip(files, instrumented) {
            let destination = directory.appending(path: file.name)
            do {
                try Data(built.source.utf8).write(to: destination)
            } catch {
                throw ValidationError("\(destination.path) could not be written: \(error)")
            }
            paths.append(destination.path)
        }
        return paths
    }

    /// One compile over the current discoveries, kept if the compiler accepts it.
    private func confirm(
        _ files: [FileUnderValidation], discoveries: [FileDiscovery]
    ) async throws(ValidationError) -> (files: [ValidatedFile], rounds: Int) {
        let instrumented = try Self.instrument(files, as: discoveries)
        let paths = try write(instrumented, for: files)
        let output = await compiler.typecheck(paths)
        guard output.exitCode == 0 else {
            throw ValidationError(
                """
                the tree still does not compile with every refused mutant removed, which \
                means the file does not compile on its own.
                """,
                diagnostics: CompilerDiagnostic.parse(output.text)
            )
        }
        return (zip(paths, instrumented).map { ValidatedFile(path: $0, instrumented: $1) }, 1)
    }

    // MARK: - Bisection

    /// Halves the whole catalogue until the refusals are cornered.
    ///
    /// Over every file at once, not one file at a time. Narrowing a single file while the
    /// others keep all their mutants asks a question nobody wanted the answer to: "does
    /// this file compile while every other file is still full of possibly-refused
    /// mutants". The answer is no whenever *any* file has a bad mutant, and the innocent
    /// file being narrowed is what gets blamed. Measured on this repository the first time
    /// it ran: five refused mutants in four other files, and the accusation landed on a
    /// fifth that was fine.
    ///
    /// Costs a compile per halving rather than one per mutant, which is the only thing
    /// that makes it an acceptable fallback. It assumes mutants are independent - that a
    /// pair which each compile alone also compile together - which holds for guards that
    /// are separate expressions and is why the assumption is worth stating.
    private struct Bisection {
        var rejected: [Rejection] = []
        var discoveries: [FileDiscovery]
        var rounds = 0
    }

    /// One candidate, and which file it came from.
    private struct Located: Hashable {
        let file: Int
        let key: Key
    }

    private func bisect(
        _ files: [FileUnderValidation], discoveries: [FileDiscovery]
    ) async throws(ValidationError) -> Bisection {
        // Nothing at all in, anywhere. If that does not build, the package does not build,
        // and none of the errors are about anything this tool did.
        let bare = try await compiles([], files: files, discoveries: discoveries)
        guard bare.compiles else {
            throw ValidationError(
                """
                the package does not build with no mutants in it at all, so the errors the \
                compiler reported are not about anything swift-mutants did.
                """,
                diagnostics: bare.diagnostics
            )
        }

        let everything = discoveries.enumerated().flatMap { position, discovery in
            discovery.candidates.map { Located(file: position, key: Key($0.span, $0.rule)) }
        }
        let found = try await search(everything, files: files, discoveries: discoveries)

        var result = Bisection(discoveries: discoveries, rounds: bare.rounds + found.rounds)
        let refused = Set(found.refused)
        for position in discoveries.indices {
            let here = refused.filter { $0.file == position }.map(\.key)
            guard !here.isEmpty else { continue }
            let keys = Set(here)
            result.discoveries[position] = discoveries[position].keeping {
                !keys.contains(Key($0.span, $0.rule))
            }
            result.rejected += try Self.rejections(
                matching: keys, in: files[position], discovery: discoveries[position])
        }
        return result
    }

    /// Whether the tree compiles with only these candidates in it, anywhere.
    ///
    /// A method rather than a closure over the search's state. Local functions that capture
    /// and mutate a `var` across an `await` are a shape this code had once and does not
    /// have now: the count comes back as a value, so there is nothing shared to get wrong -
    /// and an optimised build no longer dies in `swift_retain` part way through.
    private func compiles(
        _ subset: [Located],
        files: [FileUnderValidation],
        discoveries: [FileDiscovery]
    ) async throws(ValidationError) -> Attempt {
        var byFile: [Int: Set<Key>] = [:]
        for located in subset { byFile[located.file, default: []].insert(located.key) }

        let trial = discoveries.enumerated().map { position, discovery in
            let keep = byFile[position] ?? []
            return discovery.keeping { keep.contains(Key($0.span, $0.rule)) }
        }
        let instrumented = try Self.instrument(files, as: trial)
        let paths = try write(instrumented, for: files)
        let output = await compiler.typecheck(paths)
        return Attempt(
            compiles: output.exitCode == 0,
            rounds: 1,
            diagnostics: output.exitCode == 0 ? [] : CompilerDiagnostic.parse(output.text)
        )
    }

    /// One compile of one subset, and what it cost.
    private struct Attempt {
        let compiles: Bool
        let rounds: Int
        let diagnostics: [CompilerDiagnostic]
    }

    /// Halves a subset until the refusals are cornered.
    private func search(
        _ subset: [Located],
        files: [FileUnderValidation],
        discoveries: [FileDiscovery]
    ) async throws(ValidationError) -> (refused: [Located], rounds: Int) {
        let attempt = try await compiles(subset, files: files, discoveries: discoveries)
        guard !attempt.compiles else { return ([], attempt.rounds) }
        guard subset.count > 1 else { return (subset, attempt.rounds) }

        let middle = subset.count / 2
        let left = try await search(
            Array(subset[..<middle]), files: files, discoveries: discoveries)
        let right = try await search(
            Array(subset[middle...]), files: files, discoveries: discoveries)
        return (left.refused + right.refused, attempt.rounds + left.rounds + right.rounds)
    }

    /// Turns refused candidates back into rejections, with no compiler words to attach.
    ///
    /// Bisection learns *that* a mutant was refused without learning what was said about
    /// it - the compile that refused it said nothing placeable. The rejection is recorded
    /// with an empty diagnostic list rather than with a sentence this tool made up.
    private static func rejections(
        matching keys: Set<Key>, in file: FileUnderValidation, discovery: FileDiscovery
    ) throws(ValidationError) -> [Rejection] {
        let onlyThese = discovery.keeping { keys.contains(Key($0.span, $0.rule)) }
        let instrumented = try Self.instrument(
            [file], as: [onlyThese]
        )
        return (instrumented.first?.mutants ?? [])
            .sorted { ($0.span.start, $0.index) < ($1.span.start, $1.index) }
            .map { Rejection(identity: $0.identity, rule: $0.rule, span: $0.span, diagnostics: []) }
    }
}
