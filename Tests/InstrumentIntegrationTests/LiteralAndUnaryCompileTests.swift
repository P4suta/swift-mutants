// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsInstrument

/// The compiler's opinion of a literal moved by one, and of a negation taken away.
///
/// A literal is the one thing in a program whose type is decided entirely by where it sits,
/// so this is the family most likely to be fine in isolation and refused in place: the same
/// `3` is an `Int`, a `Double`, an index and a generic parameter depending on nothing that
/// discovery can see.
@Suite("Compiling a literal and a negation", .tags(.integration))
struct LiteralAndUnaryCompileTests {

    static func instrument(_ source: String) throws -> InstrumentedFile {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        return try Instrument.file(
            source,
            discovery: Discover.candidates(in: source, at: path, selecting: mutation))
    }

    /// Every place a literal's type comes from somewhere other than the literal.
    static let source = """
        func counted(_ xs: [Int]) -> Int { xs.count + 1 }
        func scaled(_ x: Double) -> Double { x * 2 }
        func indexed(_ xs: [Int]) -> Int { xs[0] }
        func spaced(_ n: Int) -> [Int] { Array(repeating: 0, count: n) }
        func wide(_ n: UInt64) -> UInt64 { n & 7 }
        func separated() -> Int { 1_000_000 }

        func negated(_ x: Int) -> Int { -x }
        func negatedDouble(_ x: Double) -> Double { -x }
        func literalNegative() -> Int { -1 }
        """

    /// The premise: without both families landing, this compiles an ordinary file.
    @Test("offers both families in the fixture")
    func theRulesAreThere() throws {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        let found = Set(
            Discover.candidates(in: Self.source, at: path, selecting: mutation)
                .candidates.map(\.rule.name))
        #expect(found.contains("literal-one-more"), "\(found)")
        #expect(found.contains("literal-one-less"), "\(found)")
        #expect(found.contains("drop-negation"), "\(found)")
    }

    @Test("compiles every literal and every negation")
    func compiles() throws {
        let instrumented = try Self.instrument(Self.source)
        let said = try InlinableTests.compile(["Subject.swift": instrumented.source])
        #expect(said.exitCode == 0, "\(said.text)")
    }

    @Test("compiles them under library evolution")
    func underLibraryEvolution() throws {
        let instrumented = try Self.instrument(
            Self.source.replacingOccurrences(of: "func ", with: "public func "))
        let said = try InlinableTests.compile(
            ["Subject.swift": instrumented.source], extra: ["-enable-library-evolution"])
        #expect(said.exitCode == 0, "\(said.text)")
    }
}
