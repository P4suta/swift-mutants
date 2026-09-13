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

    /// Which rule produced it.
    public let rule: RuleIdentifier
}

/// A file this tool could not instrument.
public struct InstrumentError: Error, Hashable, CustomStringConvertible {
    /// What went wrong, in the words a fix needs.
    public let description: String

    init(_ description: String) { self.description = description }
}
