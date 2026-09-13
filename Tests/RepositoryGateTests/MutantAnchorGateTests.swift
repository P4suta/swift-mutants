// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Gates that keep a mutation site anchored to bytes rather than to a syntax tree.
@Suite("Mutant anchor gate")
struct MutantAnchorGateTests {

    /// `SwiftSyntax.SyntaxIdentifier` is meaningful only within one parse of one tree.
    ///
    /// Muter stored its mutation schemata in a dictionary keyed on it, then re-parsed
    /// every file before splicing them in. The re-parsed nodes carried fresh identities,
    /// so not one key matched, **zero** mutants were inserted, and the run went on to
    /// report roughly four hundred mutants as newly surviving
    /// (muter-mutation-testing/muter#307).
    ///
    /// swift-mutants has no use for the type: a site is a ``SourceSpan`` of UTF-8 byte
    /// offsets plus a content hash, which are facts about the bytes and therefore survive
    /// a re-parse, a swift-syntax upgrade, and a round trip through a plan file. So the
    /// gate is the blunt one - the name must not appear in shipped code at all - because
    /// "appears nowhere" is a property a reader can check and "is never used as a key" is
    /// not. Prose is exempt: `SourceSpan`'s own documentation names the type in order to
    /// say it must never be used.
    @Test("SyntaxIdentifier appears nowhere in shipped source")
    func syntaxIdentifierIsAbsentFromSources() throws {
        let offenders = try RepositoryGate.swiftFiles(under: "Sources")
            .filter { try RepositoryGate.codeLines(of: $0).contains("SyntaxIdentifier") }
            .map(RepositoryGate.repositoryRelativePath)

        #expect(
            offenders.isEmpty,
            """
            SyntaxIdentifier must not appear in Sources/. It is valid only within one \
            parse of one tree; anchoring a mutation site on it is what silently inserted \
            zero mutants in muter#307. Use SourceSpan plus a content hash.
            Offending files: \(offenders.sorted().joined(separator: ", "))
            """
        )
    }
}
