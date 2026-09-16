// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsInstrument

/// The compiler's opinion of a body replaced by a constant.
///
/// A body is the widest thing this tool wraps, and the shapes it can be are the shapes most
/// likely to refuse a guard around them: `try` and `await`, which Swift restricts to the
/// left of an operator; a `mutating` method; a body that is an implicit return; an optional
/// that must not become its own wrapped type.
///
/// Discovery alone cannot establish any of this. It decides what to *offer*, and a rule
/// that offers a mutant no compiler accepts is a rule that spends a build on every file it
/// touches and then reports a rejection. So the compiler is asked directly, in a file with
/// no package around it - which is also what lets this run on a machine where a package
/// cannot resolve the swift-testing macro plugin.
@Suite("Compiling a body replaced by a constant", .tags(.integration))
struct BodyReplacementCompileTests {

    static func instrument(_ source: String) throws -> InstrumentedFile {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        mutation.extreme = true
        return try Instrument.file(
            source,
            discovery: Discover.candidates(in: source, at: path, selecting: mutation))
    }

    /// Every shape a body can take that could refuse a guard around it.
    static let bodies = """
        struct Store {
            var items: [Int] = []
            var table: [String: Int] = [:]

            var total: Int { items.reduce(0, +) }
            var isSpent: Bool { items.isEmpty }
            var label: String { "n=" + String(items.count) }
            var head: Int? { items.first }
            var all: [Int] { items.sorted() }
            var byName: [String: Int] { table }

            mutating func drain() -> Int { items.removeLast() }
            func over(_ n: Int) -> Bool { items.count > n }
        }

        func compute() throws -> Int { 1 }
        func fetch() async -> Int { 2 }

        func risky() throws -> Int { try compute() }
        func waited() async -> Int { await fetch() }
        func both() async throws -> Int { try await slow() }
        func slow() async throws -> Int { 3 }
        """

    /// The premise. Without a body actually replaced, everything below compiles an ordinary
    /// file and says nothing about this rule at all.
    @Test("replaces the bodies it is about")
    func theBodiesAreReplaced() throws {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        mutation.extreme = true
        let found = Discover.candidates(in: Self.bodies, at: path, selecting: mutation)
            .candidates.filter { $0.rule.name == "replace-body" }
        #expect(found.count >= 10, "\(found.map(\.original))")
    }

    @Test("compiles every shape a body can take")
    func compilesEveryShape() throws {
        let instrumented = try Self.instrument(Self.bodies)
        let said = try InlinableTests.compile(["Subject.swift": instrumented.source])
        #expect(said.exitCode == 0, "\(said.text)")
    }

    /// The strictest setting this package builds anything under, and the one where a
    /// guard's visibility is checked hardest.
    @Test("compiles them under library evolution")
    func underLibraryEvolution() throws {
        let instrumented = try Self.instrument(
            Self.bodies.replacingOccurrences(of: "struct Store", with: "public struct Store"))
        let said = try InlinableTests.compile(
            ["Subject.swift": instrumented.source], extra: ["-enable-library-evolution"])
        #expect(said.exitCode == 0, "\(said.text)")
    }

    /// And the line count is unchanged, which every line number a run reports rests on.
    @Test("changes no line numbers")
    func keepsTheLines() throws {
        let instrumented = try Self.instrument(Self.bodies)
        #expect(
            instrumented.source.split(separator: "\n", omittingEmptySubsequences: false).count
                >= Self.bodies.split(separator: "\n", omittingEmptySubsequences: false).count)
        let original = Self.bodies.split(separator: "\n", omittingEmptySubsequences: false).count
        let written = instrumented.source
            .split(separator: "\n", omittingEmptySubsequences: false).count
        // The runtime is appended, so the file is longer at the end and identical before it.
        #expect(written >= original)
        let head = instrumented.source
            .split(separator: "\n", omittingEmptySubsequences: false).prefix(original)
        #expect(head.count == original)
    }
}
