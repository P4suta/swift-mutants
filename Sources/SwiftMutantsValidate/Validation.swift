// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

import SwiftMutantsCore
public import SwiftMutantsDiscover
public import SwiftMutantsInstrument

/// What a compiler said, and whether it was happy.
public struct CompilerOutput: Sendable, Hashable {

    /// What the compiler exited with. Zero means it accepted the tree.
    public let exitCode: Int32

    /// Everything it wrote, standard output and standard error together.
    ///
    /// Together because a diagnostic is a diagnostic whichever stream it came out of, and
    /// interleaving order is not something to build a parser on.
    public let text: String

    /// Records what a compiler said.
    public init(exitCode: Int32, text: String) {
        self.exitCode = exitCode
        self.text = text
    }
}

/// Asks a compiler whether a tree is well-typed, without generating code.
///
/// Narrow on purpose. Validation needs exactly one thing from a build system - "would this
/// compile, and if not, what did you say" - and everything else about how a package is
/// built belongs to the build system rather than here.
public protocol TypecheckDriver: Sendable {

    /// Typechecks these files, returning everything the compiler said about them.
    ///
    /// Never throws: a compiler that refuses a tree is the ordinary case and its exit code
    /// is data. A compiler that could not be started at all is reported the same way, with
    /// whatever went wrong in the text, because a caller that has to distinguish those two
    /// from a thrown error would get it wrong exactly when a machine is misconfigured.
    func typecheck(_ paths: [String]) async -> CompilerOutput
}

/// One file on its way through validation.
public struct FileUnderValidation: Sendable {

    /// What the file is called inside the directory it is written to.
    public let name: String

    /// The file the user wrote.
    public let source: String

    /// What was found in it.
    public let discovery: FileDiscovery

    /// Describes a file to validate.
    public init(name: String, source: String, discovery: FileDiscovery) {
        self.name = name
        self.source = source
        self.discovery = discovery
    }
}

/// One file that the compiler agreed to.
public struct ValidatedFile: Sendable {

    /// Where it was written.
    public let path: String

    /// The instrumented file, holding only the mutants the compiler accepted.
    public let instrumented: InstrumentedFile
}

/// What validation established.
public struct Validation: Sendable {

    /// The files, holding only what the compiler accepted.
    public let files: [ValidatedFile]

    /// What it refused, in its own words.
    public let rejected: [Rejection]

    /// How many compiles it took.
    ///
    /// Recorded because it is the cost, and because a run that needed many rounds is
    /// saying something about the catalogue that a reader should see.
    public let rounds: Int

    /// Whether the loop had to fall back to halving.
    ///
    /// A compile that will not say what it is complaining about is worth knowing about:
    /// it usually means a diagnostic arrived from a macro buffer or a synthesised
    /// declaration, and it costs a compile per halving instead of one for the lot.
    public let bisected: Bool
}

/// Validation could not finish.
public struct ValidationError: Error, Hashable, CustomStringConvertible {

    /// What went wrong, and the first of what the compiler said about it.
    ///
    /// The compiler's own words are in here rather than only in ``diagnostics``, because
    /// this is the string that reaches a person - and "it did not compile" without the
    /// sentence saying why is the least useful error a tool can produce. Bounded, because
    /// a broken tree produces hundreds and the first few are the ones that explain it.
    public var description: String {
        guard !diagnostics.isEmpty else { return reason }
        // Errors first, and warnings only if there are no errors. A failed build reports
        // hundreds of both, the first few of which are usually warnings from somewhere
        // unrelated - and a reader given those is a reader looking in the wrong file.
        let errors = diagnostics.filter { $0.severity == .error }
        let shown = errors.isEmpty ? diagnostics : errors
        let said = shown.prefix(5).map {
            "  \($0.file):\($0.position): \($0.severity.rawValue): \($0.message)"
        }
        let more = shown.count > 5 ? "\n  ... and \(shown.count - 5) more" : ""
        return "\(reason)\n\n\(said.joined(separator: "\n"))\(more)"
    }

    /// What went wrong, without the compiler's words.
    public let reason: String

    /// Everything the compiler said, when it was the compiler that refused.
    public let diagnostics: [CompilerDiagnostic]

    init(_ reason: String, diagnostics: [CompilerDiagnostic] = []) {
        self.reason = reason
        self.diagnostics = diagnostics
    }
}
