// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsInstrument

/// The compiler's opinion of the two families Swift has that other languages do not.
///
/// Both are about types rather than about syntax, which is exactly why reasoning about them
/// is not enough. A range swapped for the other range is the same type; the *default* side
/// of a coalescing operator is the same type; its *value* side is not, and the first version
/// of that rule kept the operand as it stood - which would have compiled nowhere the result
/// was used, and generated nothing but rejections for every `??` in a package.
///
/// So the compiler is asked, in a file with no package around it.
@Suite("Compiling a range and an optional", .tags(.integration))
struct RangeAndOptionalCompileTests {

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

    /// Every shape where the type of the result is decided by something other than the
    /// operator itself.
    static let source = """
        func slice(_ xs: [Int], _ n: Int) -> [Int] { Array(xs[0..<n]) }
        func closed(_ xs: [Int], _ n: Int) -> [Int] { Array(xs[0...n]) }
        func counted(_ n: Int) -> Int { (0..<n).count }

        func plain(_ a: Int?, _ b: Int) -> Int { a ?? b }
        func nested(_ a: Int?, _ b: Int?, _ c: Int) -> Int { a ?? b ?? c }
        func chained(_ a: String?, _ b: String) -> String { a ?? b }
        func cast(_ any: Any, _ b: Int) -> Int { (any as? Int) ?? b }
        func called(_ a: Int?, _ b: () -> Int) -> Int { a ?? b() }
        """

    /// The premise: without both families actually landing, this compiles an ordinary file.
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
        #expect(found.contains("range-one-further"), "\(found)")
        #expect(found.contains("coalesce-to-default"), "\(found)")
        #expect(found.contains("coalesce-to-force"), "\(found)")
    }

    @Test("compiles every range and every coalescing mutant")
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
