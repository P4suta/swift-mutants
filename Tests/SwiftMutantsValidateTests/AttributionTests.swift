// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import Testing

@testable import SwiftMutantsValidate

/// Deciding which mutant a compiler error is about.
///
/// This is what turns one compile into every rejection. `swiftc` reports all the errors in
/// a file rather than stopping at the first, and points `line:col` at the operator inside
/// the branch that broke - so joining those positions against the spans the instrumenter
/// recorded names each refused mutant directly. The alternative is bisection: a compile per
/// halving, on a toolchain where a compile is the expensive thing.
///
/// The join is sound because the spans are disjoint. A guard's mutated side holds a
/// pristine copy of the expression with one edit in it and no nested guards, so a position
/// inside one belongs to one mutant - and a position outside all of them is a fact about
/// the original program, which is a different thing and has to be said differently.
@Suite("Attribution")
struct AttributionTests {

    static let path = "/tmp/pkg/Subject.swift"

    static func instrument(_ source: String) throws -> InstrumentedFile {
        guard let relative = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return try Instrument.file(source, discovery: Discover.candidates(in: source, at: relative))
    }

    /// Writes the diagnostic a compiler would write for a given mutant, by looking up
    /// where that mutant's copy actually is.
    static func diagnostic(
        for rule: String,
        in file: InstrumentedFile,
        offsetBy shift: Int = 0,
        severity: CompilerDiagnostic.Severity = .error
    ) throws -> String {
        let mutant = try #require(file.mutants.first { $0.rule.name == rule })
        let index = LineIndex(file.source)
        let place = try #require(index.position(of: mutant.instrumentedSpan.start + shift))
        return "\(Self.path):\(place.line):\(place.column): \(severity.rawValue): no"
    }

    @Test("names the mutant whose copy the error is in")
    func namesTheMutant() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse(try Self.diagnostic(for: "lt-to-le", in: file)),
            to: [Self.path: file]
        )
        #expect(attribution.rejected.map(\.rule.name) == ["lt-to-le"])
        #expect(attribution.unattributed.isEmpty)
    }

    /// The property the whole approach rests on: several refused mutants, one compile.
    @Test("names every refused mutant from one compile")
    func namesAllOfThem() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b && a > b }")
        let output = [
            try Self.diagnostic(for: "lt-to-le", in: file),
            try Self.diagnostic(for: "gt-to-ge", in: file),
            try Self.diagnostic(for: "and-keep-lhs", in: file),
        ].joined(separator: "\n")

        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse(output), to: [Self.path: file])
        #expect(
            attribution.rejected.map(\.rule.name).sorted()
                == ["and-keep-lhs", "gt-to-ge", "lt-to-le"]
        )
        #expect(attribution.unattributed.isEmpty)
    }

    /// A mutant the compiler refuses twice is one rejection with two sentences, not two
    /// rejections: a mutant is refused or it is not.
    @Test("gathers every word the compiler said about one mutant")
    func gathersDiagnostics() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        let output = [
            try Self.diagnostic(for: "lt-to-le", in: file),
            try Self.diagnostic(for: "lt-to-le", in: file, offsetBy: 1),
        ].joined(separator: "\n")

        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse(output), to: [Self.path: file])
        #expect(attribution.rejected.count == 1)
        #expect(attribution.rejected.first?.diagnostics.count == 2)
    }

    /// An error in the original program is not a rejection. Treating it as one would blame
    /// a mutant for the state of the file and quietly drop a mutant that compiles.
    @Test("says when an error belongs to no mutant")
    func unattributed() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse("\(Self.path):1:1: error: no"), to: [Self.path: file])
        #expect(attribution.rejected.isEmpty)
        #expect(attribution.unattributed.count == 1)
    }

    /// Only errors reject. A warning inside a mutant's copy says nothing about whether the
    /// compiler will build it, and a tool that rejected on warnings would lose mutants
    /// whenever a package turned a new diagnostic on.
    @Test("rejects on errors alone")
    func warningsDoNotReject() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        let output = [
            try Self.diagnostic(for: "lt-to-le", in: file, severity: .warning),
            try Self.diagnostic(for: "lt-to-le", in: file, severity: .note),
        ].joined(separator: "\n")

        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse(output), to: [Self.path: file])
        #expect(attribution.rejected.isEmpty)
        #expect(attribution.unattributed.isEmpty)
    }

    /// A diagnostic about a file this run did not instrument is somebody else's business,
    /// but it is still an error the build has, so it is not thrown away either.
    @Test("keeps an error about a file it does not know")
    func unknownFile() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        // The position of a real mutant, under a name this run did not instrument. A join
        // that matched on position alone would reject a mutant because of an error in
        // somebody else's file, and the two files need not even be the same length.
        let elsewhere = try Self.diagnostic(for: "lt-to-le", in: file)
            .replacingOccurrences(of: Self.path, with: "/tmp/pkg/Other.swift")
        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse(elsewhere), to: [Self.path: file])
        #expect(attribution.rejected.isEmpty)
        #expect(attribution.unattributed.count == 1)
    }

    /// Reported in source order, not in the order the compiler happened to complain,
    /// because this ends up in a report a person diffs against yesterday's.
    @Test("reports rejections in source order whatever order they arrived in")
    func sourceOrder() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b && a > b }")
        let forwards = [
            try Self.diagnostic(for: "and-to-or", in: file),
            try Self.diagnostic(for: "gt-to-ge", in: file),
            try Self.diagnostic(for: "lt-to-le", in: file),
        ]
        // `<` comes before `&&`, which comes before `>`.
        let expected = ["lt-to-le", "and-to-or", "gt-to-ge"]

        let one = Attribute.diagnostics(
            CompilerDiagnostic.parse(forwards.joined(separator: "\n")), to: [Self.path: file])
        let other = Attribute.diagnostics(
            CompilerDiagnostic.parse(forwards.reversed().joined(separator: "\n")),
            to: [Self.path: file]
        )
        #expect(one.rejected.map(\.rule.name) == expected)
        #expect(other.rejected.map(\.rule.name) == expected)
    }

    /// Two mutants that edit the same bytes - the prunes at a connective - still need a
    /// fixed order between them, and the only thing that separates them is their index.
    @Test("orders mutants that share a span by the index the guard spells")
    func tiesBrokenByIndex() throws {
        let file = try Self.instrument("func f(_ a: Bool, _ b: Bool) -> Bool { a && b }")
        let output = [
            try Self.diagnostic(for: "and-keep-rhs", in: file),
            try Self.diagnostic(for: "and-keep-lhs", in: file),
        ].joined(separator: "\n")

        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse(output), to: [Self.path: file])
        #expect(attribution.rejected.map(\.rule.name) == ["and-keep-lhs", "and-keep-rhs"])
    }

    /// The runtime is appended past every mutant, so a diagnostic in it is about generated
    /// code rather than about anything the user wrote - and must not reject a mutant.
    @Test("does not blame a mutant for an error in the runtime")
    func runtimeErrors() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        let index = LineIndex(file.source)
        let lastLine = file.source.split(separator: "\n", omittingEmptySubsequences: false).count
        _ = index
        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse("\(Self.path):\(lastLine - 1):1: error: no"),
            to: [Self.path: file]
        )
        #expect(attribution.rejected.isEmpty)
        #expect(attribution.unattributed.count == 1)
    }
}

/// The same file, named two ways.
///
/// On macOS `/var` is a symlink to `/private/var`, so a temporary directory is `/var/...`
/// to the tool that made it and `/private/var/...` to the compiler that was handed a file
/// inside it. Comparing the strings therefore matches nothing at all: every diagnostic is
/// unattributed, every compile "explains nothing", and a run that should have named its
/// rejections in one build instead halves its way through the catalogue and then blames an
/// innocent file. That is exactly what happened the first time this was pointed at a real
/// package.
///
/// Real paths, on a real filesystem, because the normalisation is the filesystem's: a
/// fixture of made-up strings would pass against a rule that merely stripped a prefix.
@Suite("Attribution across path spellings")
struct AttributionPathTests {

    static func instrument(_ source: String) throws -> InstrumentedFile {
        guard let relative = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return try Instrument.file(source, discovery: Discover.candidates(in: source, at: relative))
    }

    static func diagnostic(
        at path: String, for rule: String, in file: InstrumentedFile
    ) throws
        -> String
    {
        let mutant = try #require(file.mutants.first { $0.rule.name == rule })
        let place = try #require(LineIndex(file.source).position(of: mutant.instrumentedSpan.start))
        return "\(path):\(place.line):\(place.column): error: no"
    }

    /// A real file under the temporary directory, named both ways.
    struct Fixture {
        let asMade: String
        let asResolved: String
        let directory: URL
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    static func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "Subject.swift")
        try Data("placeholder".utf8).write(to: file)
        // How the tool names it, and how the compiler names it: on macOS `/var` is a
        // symlink to `/private/var`, and a compiler handed a file under a temporary
        // directory reports the second spelling.
        return Fixture(
            asMade: file.path,
            asResolved: "/private" + file.path,
            directory: directory
        )
    }

    @Test("finds the mutant however the compiler spelled the path")
    func matchesAcrossSpellings() throws {
        let paths = try Self.fixture()
        defer { paths.cleanUp() }
        // The premise: the two spellings differ, or this test proves nothing.
        #expect(paths.asMade != paths.asResolved, "the two spellings must actually differ")

        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        for (recorded, reported) in [
            (paths.asMade, paths.asResolved), (paths.asResolved, paths.asMade),
        ] {
            let attribution = Attribute.diagnostics(
                CompilerDiagnostic.parse(
                    try Self.diagnostic(at: reported, for: "lt-to-le", in: file)),
                to: [recorded: file]
            )
            #expect(attribution.rejected.map(\.rule.name) == ["lt-to-le"])
            #expect(attribution.unattributed.isEmpty)
        }
    }

    /// Two genuinely different files must still be told apart. Seeing through a link is
    /// not licence to match anything that ends the same way.
    @Test("still refuses a different file that ends the same way")
    func differentFile() throws {
        let paths = try Self.fixture()
        defer { paths.cleanUp() }
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")

        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse(
                try Self.diagnostic(at: "/elsewhere/Subject.swift", for: "lt-to-le", in: file)),
            to: [paths.asMade: file]
        )
        #expect(attribution.rejected.isEmpty)
        #expect(attribution.unattributed.count == 1)
    }
}

/// When the compiler points at the wrong arm of the ternary.
///
/// A guard is one type-checking problem, so a mutant that does not typecheck can be
/// reported at a position inside the *untouched* copy beside it. Measured on this
/// repository: `ContinuousClock.now - start` mutated to `+`, and the error landed on the
/// original. Nothing is wrong with that - the compiler is describing an overload it could
/// not resolve and it picked one of the places involved - but exact-span attribution
/// misses it, and a run then halves its way through six hundred mutants for one.
///
/// So a position anywhere inside a guard counts, when that guard holds one mutant. Where
/// several share a site, a position outside all their copies names none of them, and
/// guessing would reject a mutant that compiles perfectly well.
@Suite("Attribution inside a guard")
struct AttributionSiteTests {

    static let path = "/tmp/pkg/Subject.swift"

    static func instrument(_ source: String) throws -> InstrumentedFile {
        guard let relative = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return try Instrument.file(source, discovery: Discover.candidates(in: source, at: relative))
    }

    /// A diagnostic at a byte inside the guard but outside every mutated copy.
    static func diagnosticInOriginal(of file: InstrumentedFile, rule: String) throws -> String {
        let mutant = try #require(file.mutants.first { $0.rule.name == rule })
        // The last byte of the site is the closing parenthesis of the whole guard, which
        // is inside the site and outside every copy.
        let offset = mutant.siteSpan.end - 1
        #expect(!mutant.instrumentedSpan.contains(offset: offset))
        let place = try #require(LineIndex(file.source).position(of: offset))
        return "\(Self.path):\(place.line):\(place.column): error: no"
    }

    @Test("names the mutant when its guard holds only one")
    func oneMutantAtTheSite() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Int { a - b }")
        #expect(file.mutants.count == 1)

        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse(
                try Self.diagnosticInOriginal(of: file, rule: "sub-to-add")),
            to: [Self.path: file]
        )
        #expect(attribution.rejected.map(\.rule.name) == ["sub-to-add"])
        #expect(attribution.unattributed.isEmpty)
    }

    /// Three mutants share the guard around `a && b`. A position in the original arm says
    /// nothing about which of them the compiler refused, so it says so rather than
    /// rejecting two mutants that compile.
    @Test("refuses to choose when a guard holds several")
    func severalMutantsAtTheSite() throws {
        let file = try Self.instrument("func f(_ a: Bool, _ b: Bool) -> Bool { a && b }")
        #expect(file.mutants.count == 3)

        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse(
                try Self.diagnosticInOriginal(of: file, rule: "and-to-or")),
            to: [Self.path: file]
        )
        #expect(attribution.rejected.isEmpty)
        #expect(attribution.unattributed.count == 1)
    }

    /// The exact span still wins. A diagnostic inside a mutant's own copy belongs to that
    /// mutant even when the site holds others.
    @Test("prefers the copy the error is actually in")
    func exactSpanWins() throws {
        let file = try Self.instrument("func f(_ a: Bool, _ b: Bool) -> Bool { a && b }")
        let mutant = try #require(file.mutants.first { $0.rule.name == "and-to-or" })
        let place = try #require(
            LineIndex(file.source).position(of: mutant.instrumentedSpan.start))

        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse("\(Self.path):\(place.line):\(place.column): error: no"),
            to: [Self.path: file]
        )
        #expect(attribution.rejected.map(\.rule.name) == ["and-to-or"])
    }

    /// An error outside every guard is about the file rather than about a mutant, and
    /// widening the search must not swallow that.
    @Test("still says when an error belongs to no mutant")
    func outsideEveryGuard() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Int { a - b }")
        let attribution = Attribute.diagnostics(
            CompilerDiagnostic.parse("\(Self.path):1:1: error: no"), to: [Self.path: file])
        #expect(attribution.rejected.isEmpty)
        #expect(attribution.unattributed.count == 1)
    }
}
