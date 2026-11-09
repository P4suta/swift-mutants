// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutants
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import Testing

@Suite("Public source mutations")
struct MutationTests {
    static let path = "Sources/Subject.swift"
    static let source = "func compare(_ a: Int, _ b: Int) -> Bool { a < b }\n"

    static func comparison(in source: String = Self.source) throws -> Mutation {
        try #require(
            try Mutation.discover(in: source, at: Self.path).first { $0.rule == "lt-to-le" }
        )
    }

    @Test("discovers and applies a comparison through the public API")
    func comparison() throws {
        let mutation = try Self.comparison()
        #expect(mutation.path == Self.path)
        #expect(mutation.original == "<")
        #expect(mutation.replacement == "<=")
        #expect(mutation.id.count == 64)
        #expect(
            Array(Self.source.utf8)[mutation.byteRange].elementsEqual(mutation.original.utf8)
        )
        #expect(
            try mutation.applying(to: Self.source)
                == "func compare(_ a: Int, _ b: Int) -> Bool { a <= b }\n"
        )
    }

    @Test("uses the CLI's default operators and mutation identities")
    func cliParity() throws {
        let source = "func add(_ a: Int) -> Int { a + 1 }\n"
        let path = try #require(WorkspaceRelativePath(Self.path))
        let discovery = Discover.candidates(
            in: source,
            at: path
        )
        let instrumented = try Instrument.file(source, discovery: discovery)
        let mutations = try Mutation.discover(in: source, at: Self.path)
        #expect(!mutations.isEmpty)
        #expect(Set(mutations.map(\.id)) == Set(instrumented.mutants.map(\.identity.rendered)))
    }

    @Test("returns identical mutations for identical inputs")
    func deterministic() throws {
        let first = try Mutation.discover(in: Self.source, at: Self.path)
        let second = try Mutation.discover(in: Self.source, at: "Sources/./Subject.swift")
        #expect(!first.isEmpty)
        #expect(first == second)
    }

    @Test("preserves UTF-8 bytes and CRLF line endings outside the edit")
    func unicodeAndLineEndings() throws {
        let source =
            "// \u{1F600} e\u{301}\r\nfunc compare(_ a: Int, _ b: Int) -> Bool { a < b }\r\n"
        let mutation = try Self.comparison(in: source)
        let changed = try mutation.applying(to: source)
        let expected =
            "// \u{1F600} e\u{301}\r\nfunc compare(_ a: Int, _ b: Int) -> Bool { a <= b }\r\n"
        #expect(Array(changed.utf8) == Array(expected.utf8))
    }

    @Test("rejects changed source even when the edit still matches")
    func staleSource() throws {
        let mutation = try Self.comparison()
        #expect(throws: MutationError.sourceChanged(path: Self.path)) {
            try mutation.applying(to: Self.source + "// edited\n")
        }
        #expect(throws: MutationError.sourceChanged(path: Self.path)) {
            try mutation.applying(to: "")
        }
    }

    @Test("rejects canonically equivalent text with different source bytes")
    func changedUnicode() throws {
        let source = Self.source + "// \u{e9}\n"
        let changed = Self.source + "// e\u{301}\n"
        #expect(source == changed)
        let mutation = try Self.comparison(in: source)
        #expect(throws: MutationError.sourceChanged(path: Self.path)) {
            try mutation.applying(to: changed)
        }
    }

    @Test(
        "rejects invalid source paths",
        arguments: [
            "", "../Subject.swift", "/tmp/Subject.swift", "Subject.c", "C:\\Subject.swift",
            "Bad\u{0}.swift",
        ]
    )
    func invalidPath(path: String) {
        #expect(throws: MutationError.invalidPath(path)) {
            try Mutation.discover(in: Self.source, at: path)
        }
    }

    @Test("returns no mutations when the source has no candidates")
    func emptySource() throws {
        #expect(try Mutation.discover(in: "", at: Self.path).isEmpty)
    }
}
