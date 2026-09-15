// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftOperators
import SwiftParser
import SwiftSyntax
public import SwiftMutantsCore

/// Finds what could be mutated in one file, and names what was passed over.
///
/// Discovery is where a run decides what it is about. Everything downstream - the
/// catalogue, the identities, the cache keys, the score - is a consequence of it, so a
/// candidate invented here and a candidate silently dropped here are equally serious.
///
/// The tree is **folded** before it is walked. `SwiftSyntax` parses `a && b || c` as a flat
/// sequence with no precedence in it, so without folding there is no such thing as "the
/// expression this operator belongs to" - and that expression is exactly what a guard has
/// to wrap. Folding preserves every byte position, so a span still names the bytes of the
/// file the user wrote.
public enum Discover {

    /// Reads one file.
    /// `custom` are the mutants this project wrote for itself that name this file. They
    /// sit beside the generated ones rather than instead of them, because they ask a
    /// different question: the catalogue asks whether an operator is correct, and a
    /// project's own usually asks whether a piece of it is load-bearing.
    public static func candidates(
        in source: String,
        at path: WorkspaceRelativePath,
        custom: [CustomMutant] = []
    ) -> FileDiscovery {
        let tree = Parser.parse(source: source)
        let folded = OperatorTable.standardOperators.foldAll(tree) { _ in }

        let suppressions = Suppressions(source: source)
        let walker = CandidateWalker(
            locations: SourceLocationConverter(fileName: "<source>", tree: folded),
            suppressions: suppressions
        )
        walker.walk(folded)

        let own = Self.anchored(custom, in: source, lines: LineIndex(source))
        return FileDiscovery(
            path: path,
            sourceDigest: Digest.of(source),
            candidates: (walker.candidates + own.candidates).sorted { $0.span < $1.span },
            skips: (walker.skips + own.skips).sorted { $0.span < $1.span },
            unknownSuppressions: suppressions.unknownFamilies
                .map { UnknownSuppression(line: $0.line, name: $0.name) }
                .sorted { ($0.line, $0.name) < ($1.line, $1.name) },
            unanchored: own.unanchored
        )
    }
}
