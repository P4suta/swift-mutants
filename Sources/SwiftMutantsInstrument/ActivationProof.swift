// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// Proves that the mutants a run is about to measure are actually there.
///
/// This exists because of a specific failure. Muter kept its mutation sites in a dictionary
/// keyed on syntax-node identity and then re-parsed each file before splicing them in; the
/// re-parsed nodes carried new identities, not one key matched, and **zero** mutants were
/// inserted. Nothing crashed. The build was clean, the run completed, and roughly four
/// hundred previously-killed mutants were reported as newly surviving
/// (muter-mutation-testing/muter#307).
///
/// The lesson is not "be careful with identities". It is that a tool must not infer that
/// its own instrumentation happened. So this asks, in two places:
///
/// - ``inSource(_:)`` asks the instrumented text whether every mutant's marker is in it,
///   exactly once. That is free, and it is precisely the check that would have caught #307.
/// - ``missingTokens(_:inSymbols:)`` asks the built product whether each instrumented
///   file's runtime reached it. A file that was spliced and then never compiled in is the
///   other way to end up measuring a program with no mutants in it.
///
/// A third layer - waking a sample of mutants and watching a probe record them - arrives
/// with the probe runtime.
public enum ActivationProof {

    /// A mutant that could not be found where it was supposed to be.
    public struct Absence: Sendable, Hashable {
        /// What the mutant is called.
        public let identity: MutantIdentity
        /// The text that should have been there.
        public let marker: String
        /// How many times it actually appeared.
        public let occurrences: Int
    }

    /// What a proof found.
    public struct Result: Sendable, Hashable {
        /// How many mutants were supposed to be there.
        public let expected: Int
        /// How many were.
        public let found: Int
        /// The ones that were not, or that were there more than once.
        public let absences: [Absence]

        /// Whether every mutant was where it should have been.
        public var isProved: Bool { absences.isEmpty }
    }

    /// Proves every mutant is in the text it was spliced into, exactly once.
    ///
    /// Exactly once rather than at least once: a marker that appears twice means two guards
    /// share an index, so activating one would wake both and the run would attribute a kill
    /// to whichever mutant it happened to be asking about.
    public static func inSource(_ file: InstrumentedFile) -> Result {
        var absences: [Absence] = []
        for mutant in file.mutants {
            let occurrences = Self.occurrences(of: mutant.marker, in: file.source)
            guard occurrences != 1 else { continue }
            absences.append(
                Absence(identity: mutant.identity, marker: mutant.marker, occurrences: occurrences)
            )
        }
        return Result(
            expected: file.mutants.count,
            found: file.mutants.count - absences.count,
            absences: absences
        )
    }

    /// Which instrumented files' runtimes did not reach the built product.
    ///
    /// The per-file token survives compilation into the symbol table, so a `nm` of the
    /// built binary answers "was this file compiled into what is about to be run". A file
    /// that was spliced and then left out - excluded by a manifest, filtered by a build
    /// setting, in a target the product does not contain - would otherwise produce mutants
    /// that can never be woken and can therefore never be killed.
    public static func missingTokens(
        _ tokens: some Sequence<String>,
        inSymbols symbols: String
    ) -> [String] {
        tokens.filter { !$0.isEmpty && !symbols.contains($0) }.sorted()
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        let wanted = Array(needle.utf8)
        let bytes = Array(haystack.utf8)
        guard bytes.count >= wanted.count else { return 0 }
        var count = 0
        for start in 0...(bytes.count - wanted.count)
        where Array(bytes[start..<(start + wanted.count)]) == wanted {
            count += 1
        }
        return count
    }
}
