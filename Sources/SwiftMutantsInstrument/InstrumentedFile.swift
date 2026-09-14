// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// One file with every one of its mutants in it, each dormant behind a guard.
public struct InstrumentedFile: Sendable, Hashable {

    /// The file as it should be written into the snapshot.
    public let source: String

    /// The runtime appended to the end of it.
    ///
    /// Appended rather than inserted, so every line above keeps its number. Empty when the
    /// file had nothing to mutate, in which case ``source`` is the original untouched.
    public let runtime: String

    /// What was put in, and what each one is called.
    public let mutants: [InstrumentedMutant]

    /// The per-file suffix this file's runtime carries.
    ///
    /// It survives compilation into the symbol table, which is what lets a proof ask the
    /// built product whether this file reached it at all.
    public let runtimeToken: String

    /// How many lines the runtime added.
    ///
    /// The only lines a file gains. Everything above the runtime keeps its number, which is
    /// what lets a coverage profile taken from the instrumented build be read against the
    /// file the user wrote.
    public var runtimeLineCount: Int {
        runtime.isEmpty
            ? 0 : runtime.split(separator: "\n", omittingEmptySubsequences: false).count - 1
    }
}

/// One mutant, as it exists in an instrumented file.
public struct InstrumentedMutant: Sendable, Hashable {

    /// What it is called. Computed from the **original** file, never the instrumented one.
    public let identity: MutantIdentity

    /// The dense index its guard spells.
    ///
    /// Dense and per-file, so a guard is an integer compare against a global the runtime
    /// read once.
    public let index: UInt32

    /// The text the activation proof looks for in the built binary.
    ///
    /// A mutant whose marker cannot be found was never spliced in. Muter assumed insertion
    /// and reported four hundred mutants as newly surviving when in fact none had been
    /// inserted at all; proving it is what makes that failure impossible rather than
    /// unlikely.
    public let marker: String

    /// Where the edit is in the original file.
    public let span: SourceSpan

    /// Where this mutant's own copy of the expression sits in the instrumented file.
    ///
    /// The span a compiler diagnostic is joined against. `swiftc` reports every error in a
    /// file rather than stopping at the first and points `line:col` at the operator inside
    /// the branch that broke, so one typecheck names every mutant the compiler refuses -
    /// bisection stays as a fallback rather than being the mechanism.
    ///
    /// These are disjoint across a file: a guard's mutated side holds a pristine flattened
    /// copy of the expression with one edit in it and no nested guards, because only one
    /// mutant is ever awake and a guard nested in there could never fire. So a diagnostic
    /// inside one of these spans belongs to one mutant, and a diagnostic outside all of
    /// them is a fact about the original program rather than about any mutant.
    public let instrumentedSpan: SourceSpan

    /// The whole guard this mutant is one alternative of, in the instrumented file.
    ///
    /// Wider than ``instrumentedSpan`` on purpose. A ternary is one type-checking problem,
    /// so a mutant that does not typecheck can be reported at a position in the *other*
    /// arm - measured here: `ContinuousClock.now - start` mutated to `+`, and the error
    /// landed on the untouched copy. Nothing is wrong with that; the compiler is
    /// describing an overload it could not resolve, and it picked one of the places
    /// involved.
    ///
    /// So attribution falls back to this when the exact span misses, and only when the
    /// site holds one mutant - where several share a site, a position outside all their
    /// copies names none of them, and guessing would reject a mutant that compiles.
    public let siteSpan: SourceSpan

    /// Which rule produced it.
    public let rule: RuleIdentifier
}

/// A file this tool could not instrument.
public struct InstrumentError: Error, Hashable, CustomStringConvertible {
    /// What went wrong, in the words a fix needs.
    public let description: String

    init(_ description: String) { self.description = description }
}
