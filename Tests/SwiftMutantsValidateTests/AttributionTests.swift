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
