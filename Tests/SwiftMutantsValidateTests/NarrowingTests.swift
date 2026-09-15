// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import SwiftMutantsSnapshot
import Testing

@testable import SwiftMutantsValidate

/// Where to look when the compiler complained about nothing this tool can name.
///
/// Halving is the expensive path - a compile per halving - so where it starts matters more
/// than anything else about it. An error nobody could attribute still has a *position*, and
/// the mutants whose site surrounds that position are the ones worth halving first.
///
/// Reported from a real package: a ternary that type-checks fine as written and tips over
/// once guards wrap its subexpressions, named down to the column, and two hundred and
/// fifty-five mutants halved because nothing used the column. Roughly eight compiles where
/// one narrowing would have done.
///
/// Nothing here rejects anything. Attribution refuses to guess between mutants that share a
/// site, and it is right to: rejecting a mutant that compiles is a hole in somebody's tests
/// nobody will ever hear about. A narrowing only decides where to look, and the halving
/// still decides what is true - which is why a narrowing may guess where attribution may
/// not.
@Suite("Where halving starts")
struct NarrowingTests {

    static let path = "/tmp/pkg/Subject.swift"

    static func instrument(_ source: String) throws -> InstrumentedFile {
        guard let relative = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return try Instrument.file(source, discovery: Discover.candidates(in: source, at: relative))
    }

    /// A diagnostic at a byte offset of the instrumented file.
    static func diagnostic(
        at offset: Int, in file: InstrumentedFile, path: String = Self.path
    )
        throws -> CompilerDiagnostic
    {
        let place = try #require(LineIndex(file.source).position(of: offset))
        let parsed = CompilerDiagnostic.parse(
            "\(path):\(place.line):\(place.column): error: the compiler is unable to "
                + "type-check this expression in reasonable time")
        return try #require(parsed.first)
    }

    /// An expression with several mutants in one site, which is the shape that defeats
    /// attribution: a position at its start is inside none of their copies.
    static let ternary = """
        func f(_ text: String, _ width: Int) -> String {
            text.count < width ? String(repeating: "0", count: width - text.count) + text : text
        }
        """

    @Test("points at the mutants whose site surrounds the error")
    func pointsAtTheSite() throws {
        let file = try Self.instrument(Self.ternary)
        let mutant = try #require(file.mutants.first)
        let found = Validator.pointedAt(
            [try Self.diagnostic(at: mutant.siteSpan.start, in: file)],
            in: Validator.Written([file], at: [Self.path])
        )
        #expect(!found.isEmpty)
        // And far fewer than the file has, which is the whole point.
        #expect(found.count <= file.mutants.count)
    }

    /// The case that was reported, in the shape that matters: a file full of mutants, an
    /// error in one expression, and a narrowing that is that expression rather than the
    /// file. Two hundred and fifty-five halved, when the compiler had named the column.
    @Test("narrows to the expression rather than the file")
    func narrowsToTheExpression() throws {
        let file = try Self.instrument(Self.crowded)
        #expect(file.mutants.count >= 6)

        let target = try #require(file.mutants.first { $0.rule.name == "sub-to-add" })
        let found = Validator.pointedAt(
            [try Self.diagnostic(at: target.siteSpan.start, in: file)],
            in: Validator.Written([file], at: [Self.path])
        )
        #expect(!found.isEmpty)
        // Fewer than half the file, which is what turns eight halvings into one.
        #expect(found.count * 2 < file.mutants.count)
        #expect(found.contains { $0.key.span == target.span })
    }

    /// Several expressions, so that narrowing to one of them is visibly narrower than
    /// narrowing to the file - which is what the file-level narrowing already did.
    static let crowded = """
        func a(_ x: Int, _ y: Int) -> Bool { x < y }
        func b(_ x: Int, _ y: Int) -> Bool { x > y }
        func c(_ x: Int, _ y: Int) -> Int { x - y }
        func d(_ x: Int, _ y: Int) -> Int { x * y }
        func e(_ x: Bool, _ y: Bool) -> Bool { x && y }
        """

    /// A position inside one mutant's copy points at that mutant, which is the easy case
    /// and still has to hold.
    @Test("points at the one whose copy the error is in")
    func pointsInsideACopy() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        let mutant = try #require(file.mutants.first)
        let found = Validator.pointedAt(
            [try Self.diagnostic(at: mutant.instrumentedSpan.start, in: file)],
            in: Validator.Written([file], at: [Self.path])
        )
        #expect(found.count == 1)
    }

    /// A diagnostic in a file this tool did not write points at nothing, and pointing at
    /// nothing is a narrowing that says nothing rather than one that says "none of them" -
    /// the caller widens instead.
    @Test("points at nothing when the file is not one of ours")
    func unknownFile() throws {
        let file = try Self.instrument(Self.ternary)
        let elsewhere = try Self.diagnostic(
            at: 0, in: file, path: "/tmp/somewhere/Else.swift")
        #expect(
            Validator.pointedAt([elsewhere], in: Validator.Written([file], at: [Self.path])).isEmpty
        )
    }

    /// A position past the end of the file names nothing, rather than naming whatever the
    /// last mutant happened to be.
    @Test("points at nothing when the position is nowhere")
    func nowhere() throws {
        let file = try Self.instrument(Self.ternary)
        let parsed = CompilerDiagnostic.parse("\(Self.path):9999:1: error: no")
        #expect(Validator.pointedAt(parsed, in: Validator.Written([file], at: [Self.path])).isEmpty)
    }

    /// The same narrowing however the temporary directory is spelled.
    ///
    /// On macOS `/var` is a symlink to `/private/var`, so the compiler and this tool name
    /// one file two ways. On a real file, which is the only way to test it: the resolution
    /// asks the filesystem rather than applying a rule about prefixes, so a path that does
    /// not exist resolves to itself and two spellings of nothing would agree for the wrong
    /// reason. Validation always has a real file - it wrote it a moment ago.
    @Test("points at the same mutants through a symlinked path")
    func throughASymlink() throws {
        let file = try Self.instrument(Self.ternary)
        let mutant = try #require(file.mutants.first)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-narrow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = directory.appending(path: "Subject.swift")
        try Data(file.source.utf8).write(to: written)

        // The two spellings the compiler and this tool each reach for.
        let asMade = written.path
        let asTheCompilerSeesIt = try #require(CanonicalPath.of(asMade))
        #expect(asMade != asTheCompilerSeesIt)

        let direct = Validator.pointedAt(
            [try Self.diagnostic(at: mutant.siteSpan.start, in: file, path: asMade)],
            in: Validator.Written([file], at: [asMade])
        )
        let linked = Validator.pointedAt(
            [
                try Self.diagnostic(
                    at: mutant.siteSpan.start, in: file, path: asTheCompilerSeesIt)
            ],
            in: Validator.Written([file], at: [asMade])
        )
        #expect(!direct.isEmpty)
        #expect(linked == direct)
    }

    /// Two runs over the same tree halve the same way, so a difference between two runs is
    /// a difference that matters. In file order, then in the order the mutants sit in the
    /// file - which a set does not give on its own.
    @Test("puts them in one order")
    func oneOrder() throws {
        let file = try Self.instrument(Self.crowded)
        let diagnostics = try file.mutants.map {
            try Self.diagnostic(at: $0.siteSpan.start, in: file)
        }
        let found = Validator.pointedAt(diagnostics, in: Validator.Written([file], at: [Self.path]))
        #expect(found.count > 3)
        #expect(found.map(\.key.span.start) == found.map(\.key.span.start).sorted())
    }

    /// A diagnostic in one file names that file's mutants, not another file's. With one
    /// file in hand any lookup looks right, which is why there are two.
    @Test("points only at the file the error was in")
    func theRightFile() throws {
        let first = try Self.instrument("func a(_ x: Int, _ y: Int) -> Bool { x < y }")
        let second = try Self.instrument(Self.crowded)
        let target = try #require(second.mutants.first)

        let found = Validator.pointedAt(
            [
                try Self.diagnostic(
                    at: target.siteSpan.start, in: second, path: "/tmp/pkg/Second.swift")
            ],
            in: Validator.Written(
                [first, second], at: ["/tmp/pkg/First.swift", "/tmp/pkg/Second.swift"])
        )
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0.file == 1 })
    }
}
