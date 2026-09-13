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
    public static func candidates(
        in source: String,
        at path: WorkspaceRelativePath
    ) -> FileDiscovery {
        let tree = Parser.parse(source: source)
        let folded = OperatorTable.standardOperators.foldAll(tree) { _ in }

        let suppressions = Suppressions(source: source)
        let walker = CandidateWalker(
            locations: SourceLocationConverter(fileName: "<source>", tree: folded),
            suppressions: suppressions
        )
        walker.walk(folded)

        return FileDiscovery(
            path: path,
            sourceDigest: Digest.of(source),
            candidates: walker.candidates.sorted { $0.span < $1.span },
            skips: walker.skips.sorted { $0.span < $1.span },
            unknownSuppressions: suppressions.unknownFamilies
                .map { UnknownSuppression(line: $0.line, name: $0.name) }
                .sorted { ($0.line, $0.name) < ($1.line, $1.name) }
        )
    }
}
