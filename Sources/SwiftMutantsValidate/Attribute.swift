// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public import SwiftMutantsCore
public import SwiftMutantsInstrument

/// A mutant the compiler refused, in the compiler's words.
///
/// A rejection is a fact about the program, not a decision this tool made, so it carries
/// the diagnostics themselves rather than a summary of them. They are caught here because
/// this is the only moment they exist: once the refused mutants are dropped the tree
/// compiles, and the sentence explaining why one of them could not is gone.
public struct Rejection: Sendable, Hashable {

    /// Which mutant.
    public let identity: MutantIdentity

    /// Which rule produced it, for a report that groups by rule.
    public let rule: RuleIdentifier

    /// Where it is in the file the user wrote, not in the instrumented copy.
    public let span: SourceSpan

    /// Everything the compiler said about it, in the order it said it.
    public let diagnostics: [CompilerDiagnostic]
}

/// What one compile of an instrumented tree established.
public struct Attribution: Sendable, Hashable {

    /// The mutants the compiler refused, ordered by where they are in their file.
    public let rejected: [Rejection]

    /// Errors that belong to no mutant.
    ///
    /// Either the original program does not compile, or a mutant broke it somewhere the
    /// compiler did not point at. The two are not distinguishable from here and must not
    /// be guessed between: a caller that sees any of these has learned that this compile
    /// did not explain itself, and bisection is what answers instead.
    public let unattributed: [CompilerDiagnostic]
}

/// Joins compiler diagnostics to the mutants they are about.
public enum Attribute {

    /// Works out which mutant each error is in.
    ///
    /// `files` is keyed by the path each instrumented file was written to, which is the
    /// path the compiler echoes back. A diagnostic naming anything else cannot be placed
    /// and is kept as unattributed rather than dropped - an error the build has is an
    /// error the build has, whoever it belongs to.
    ///
    /// Errors alone reject. A warning inside a mutant's copy says nothing about whether
    /// the compiler will build it, and a tool that rejected on warnings would lose mutants
    /// every time a package turned a new diagnostic on.
    public static func diagnostics(
        _ diagnostics: [CompilerDiagnostic],
        to files: [String: InstrumentedFile]
    ) -> Attribution {
        // One lookup, not two. Indexing a file and finding it are the same question, and
        // asking it twice leaves a branch no test can reach on its own.
        //
        // Keyed by the path with its links resolved, because the compiler resolves them
        // and this tool does not: on macOS `/var` is a symlink to `/private/var`, so a
        // temporary directory is `/var/...` to whoever made it and `/private/var/...` to
        // whoever was handed a file inside it. Comparing the strings matches nothing, and
        // nothing matching reads exactly like a compiler that explained nothing.
        var known: [String: (file: InstrumentedFile, index: LineIndex)] = [:]
        for (path, file) in files {
            known[Self.resolved(path)] = (file, LineIndex(file.source))
        }

        var found: [MutantIdentity: [CompilerDiagnostic]] = [:]
        var placed: [MutantIdentity: InstrumentedMutant] = [:]
        var unattributed: [CompilerDiagnostic] = []

        for diagnostic in diagnostics {
            guard diagnostic.severity == .error else { continue }
            guard
                let entry = known[Self.resolved(diagnostic.file)],
                let offset = entry.index.offset(of: diagnostic.position),
                let mutant = Self.mutant(at: offset, in: entry.file)
            else {
                unattributed.append(diagnostic)
                continue
            }
            found[mutant.identity, default: []].append(diagnostic)
            placed[mutant.identity] = mutant
        }

        // Ordered by where the mutant is rather than by the order the compiler happened to
        // complain, so two runs over the same tree produce the same report to diff.
        let rejected =
            placed.values
            .sorted { ($0.span.start, $0.index) < ($1.span.start, $1.index) }
            .map { mutant in
                Rejection(
                    identity: mutant.identity,
                    rule: mutant.rule,
                    span: mutant.span,
                    diagnostics: found[mutant.identity] ?? []
                )
            }
        return Attribution(rejected: rejected, unattributed: unattributed)
    }

    /// Which mutant an offset belongs to, if exactly one does.
    ///
    /// The copy it is in, first: that is the mutant the compiler is describing, and it is
    /// unambiguous. Failing that, the guard it is in - because a ternary is one
    /// type-checking problem, and a mutant that does not typecheck can be reported at a
    /// position inside the *untouched* copy beside it. Measured on this repository:
    /// `ContinuousClock.now - start` mutated to `+`, and the error landed on the original.
    ///
    /// Only when the guard holds one mutant. Where several share a site, a position
    /// outside all their copies names none of them, and guessing would reject mutants
    /// that compile perfectly well - which is the expensive mistake: a lost mutant is a
    /// hole in somebody's tests nobody will ever be told about.
    private static func mutant(at offset: Int, in file: InstrumentedFile) -> InstrumentedMutant? {
        if let exact = file.mutants.first(where: { $0.instrumentedSpan.contains(offset: offset) }) {
            return exact
        }
        let sharing = file.mutants.filter { $0.siteSpan.contains(offset: offset) }
        return sharing.count == 1 ? sharing.first : nil
    }

    /// A path with its symbolic links followed, so two spellings of one file agree.
    ///
    /// The filesystem does the normalising rather than a rule about prefixes, so two
    /// genuinely different files are still told apart - and so this keeps working on a
    /// platform whose links are somewhere else entirely. It relies on the file existing,
    /// which it does: validation wrote it a moment ago and the compiler has just read it.
    static func resolved(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().path
    }
}
