// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// Everything a run found, in one order, under one digest.
@Suite("Catalog")
struct CatalogTests {

    static func mutant(
        path: String = "Sources/Codec/Header.swift",
        rule: String = "add-to-sub@1",
        start: Int = 100,
        end: Int = 105,
        original: String = "a + b",
        replacement: String = "a - b"
    ) -> Mutant {
        guard let path = WorkspaceRelativePath(path),
            let rule = RuleIdentifier(rule),
            let span = SourceSpan(start: start, end: end)
        else {
            fatalError("malformed catalogue fixture")
        }
        return Mutant(
            path: path,
            enclosingDeclaration: "s:4Demo6HeaderV5parseyACSSKFZ",
            rule: rule,
            span: span,
            sourceDigest: Digest.of("the file"),
            original: original,
            replacement: replacement
        )
    }

    /// A catalogue read by two machines has to be the same catalogue, so the order cannot
    /// depend on how discovery happened to walk the tree.
    @Test("orders by path, then by span, then by rule")
    func deterministicOrder() throws {
        let unordered = [
            Self.mutant(path: "Sources/B.swift", start: 10, end: 12),
            Self.mutant(path: "Sources/A.swift", rule: "sub-to-add@1", start: 40, end: 42),
            Self.mutant(path: "Sources/A.swift", rule: "add-to-sub@1", start: 40, end: 42),
            Self.mutant(path: "Sources/A.swift", start: 10, end: 12),
        ]
        let catalog = try Catalog(unordered)
        #expect(
            catalog.mutants.map { "\($0.path)@\($0.span.start):\($0.rule.name)" } == [
                "Sources/A.swift@10:add-to-sub",
                "Sources/A.swift@40:add-to-sub",
                "Sources/A.swift@40:sub-to-add",
                "Sources/B.swift@10:add-to-sub",
            ]
        )
    }

    @Test("is unchanged by the order it was given")
    func orderOfArrivalDoesNotMatter() throws {
        let mutants = [
            Self.mutant(path: "Sources/A.swift", start: 10, end: 12),
            Self.mutant(path: "Sources/B.swift", start: 20, end: 22),
            Self.mutant(path: "Sources/C.swift", start: 30, end: 32),
        ]
        let one = try Catalog(mutants)
        let other = try Catalog(mutants.reversed())
        #expect(one.mutants.map(\.identity) == other.mutants.map(\.identity))
        #expect(one.digest == other.digest)
    }

    /// The catalogue digest goes into the outcome cache's key, so it has to move whenever
    /// the set of mutants moves and stay still otherwise.
    @Test("digests the identities it holds")
    func digestFollowsTheMutants() throws {
        let base = try Catalog([Self.mutant(start: 10, end: 12)])
        let same = try Catalog([Self.mutant(start: 10, end: 12)])
        let different = try Catalog([
            Self.mutant(start: 10, end: 12), Self.mutant(start: 20, end: 22),
        ])
        #expect(base.digest == same.digest)
        #expect(base.digest != different.digest)
    }

    /// Two entries with one identity would let one adopt the other's cached verdict. The
    /// catalogue refuses rather than keeping whichever came last.
    @Test("refuses two mutants with the same identity")
    func refusesDuplicateIdentity() {
        let twice = [Self.mutant(), Self.mutant()]
        #expect(throws: Catalog.Failure.self) { try Catalog(twice) }
    }

    @Test("resolves a short prefix to exactly one mutant")
    func resolvesPrefix() throws {
        let catalog = try Catalog([
            Self.mutant(start: 10, end: 12), Self.mutant(start: 20, end: 22),
        ])
        let wanted = try #require(catalog.mutants.first)
        #expect(catalog.resolve(prefix: wanted.identity.shortForm) == .one(wanted))
        #expect(catalog.resolve(prefix: String(wanted.identity.rendered.prefix(8))) == .one(wanted))
    }

    /// "Probably the one you meant" is not an answer a tool should give about an
    /// identifier, so an ambiguous prefix names every candidate and resolves to none.
    @Test("refuses to guess when a prefix names more than one")
    func refusesToGuessOnAmbiguity() throws {
        let catalog = try Catalog([
            Self.mutant(start: 10, end: 12), Self.mutant(start: 20, end: 22),
        ])
        let identities = catalog.mutants.map(\.identity)
        // The empty prefix is a prefix of everything.
        #expect(catalog.resolve(prefix: "") == .ambiguous(identities))
    }

    @Test("resolves an unknown prefix to nothing")
    func unknownPrefix() throws {
        let catalog = try Catalog([Self.mutant()])
        #expect(catalog.resolve(prefix: "ffffffffffffffffffff") == .notFound)
    }

    @Test("holds nothing when given nothing")
    func empty() throws {
        let catalog = try Catalog([])
        #expect(catalog.mutants.isEmpty)
        #expect(catalog.resolve(prefix: "a") == .notFound)
    }

    @Test("looks a mutant up by its full identity")
    func lookupByIdentity() throws {
        let catalog = try Catalog([
            Self.mutant(start: 10, end: 12), Self.mutant(start: 20, end: 22),
        ])
        let wanted = try #require(catalog.mutants.last)
        #expect(catalog[wanted.identity] == wanted)
    }
}
