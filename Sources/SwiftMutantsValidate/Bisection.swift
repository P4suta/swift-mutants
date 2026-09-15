// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument

/// Cornering refusals the compiler would not place.
///
/// The fallback path, and the one whose defects are hardest to see: it only runs when a
/// compile has already failed to explain itself, so a wrong answer here arrives looking
/// exactly like a right one. It is also the expensive one - a compile per halving, where
/// the ordinary path costs one compile for every refusal it can name.
extension Validator {

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
    struct Bisection {
        var rejected: [Rejection] = []
        var discoveries: [FileDiscovery]
        var rounds = 0
    }

    /// One candidate, and which file it came from.
    struct Located: Hashable {
        let file: Int
        let key: Key
    }

    /// Halves until the refusals are cornered, trying each narrowing before the next.
    ///
    /// `narrowings` are candidate sets to search, smallest first, and the last one should
    /// be everything: a narrowing that explains nothing is not a finding, so the search
    /// falls through to the next rather than concluding. Nothing is rejected on the
    /// strength of a narrowing - it only decides where to look, and the halving still
    /// decides what is true - which is why a narrowing may be a guess where attribution
    /// may not.
    func bisect(
        _ files: [FileUnderValidation],
        discoveries: [FileDiscovery],
        trying narrowings: [[Located]]
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

        // Smallest first, widening only when a narrowing explains nothing. A narrowing
        // that is empty, or the same as the one before it, is skipped: searching it would
        // be a compile spent proving what the last one proved.
        var found: (refused: [Located], rounds: Int) = ([], 0)
        var searched: Set<Set<Located>> = []
        for narrowing in narrowings where !narrowing.isEmpty {
            guard searched.insert(Set(narrowing)).inserted else { continue }
            let attempt = try await search(narrowing, files: files, discoveries: discoveries)
            found = (attempt.refused, found.rounds + attempt.rounds)
            if !attempt.refused.isEmpty { break }
        }

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
    func compiles(
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
    struct Attempt {
        let compiles: Bool
        let rounds: Int
        let diagnostics: [CompilerDiagnostic]
    }

    /// Halves a subset until the refusals are cornered.
    func search(
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
    static func rejections(
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
