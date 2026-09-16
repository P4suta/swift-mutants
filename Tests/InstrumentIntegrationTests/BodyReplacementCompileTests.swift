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

        // The shapes only a statement guard can reach.
        func several() -> Int {
            let a = 1
            let b = 2
            return a + b
        }

        func returnsNothing() {
            print("working")
        }

        func nothingAndThrows() throws {
            _ = try compute()
        }

        func nothingAndAwaits() async {
            _ = await fetch()
        }

        struct Counter {
            var n = 0
            mutating func bump() {
                n += 1
                n += 1
            }
            mutating func drained() -> Int {
                let was = n
                n = 0
                return was
            }
        }

        func nested() -> Int {
            func inner() -> Int {
                let a = 1
                return a + 1
            }
            return inner() + 1
        }
        """

    /// The premise. Without a body actually replaced, everything below compiles an ordinary
    /// file and says nothing about this rule at all.
    /// The other half of the premise: without a statement guard actually landing, every
    /// shape below is compiled by an expression guard and says nothing about this form.
    @Test("stops the bodies a ternary cannot reach")
    func theStatementGuardsAreThere() throws {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        mutation.extreme = true
        let found = Discover.candidates(in: Self.bodies, at: path, selecting: mutation)
            .candidates.filter { $0.rule.name == "stop-body" }
        #expect(found.count >= 7, "\(found.map(\.replacement))")
        #expect(found.contains { $0.replacement == "return" }, "a body that returns nothing")
        #expect(found.contains { $0.replacement == "return 0" }, "a body of several statements")
    }

    /// Every line number below a statement guard is what it was, which is what the coverage
    /// a run reads back afterwards rests on. A guard that landed on its own line would move
    /// the whole file down by one and silently misplace every later mutant.
    @Test("puts a statement guard on the brace's own line")
    func onTheBracesLine() throws {
        let instrumented = try Self.instrument(Self.bodies)
        let lines = instrumented.source.split(separator: "\n", omittingEmptySubsequences: false)
        let opened = lines.first { $0.contains("func returnsNothing()") }
        #expect(opened?.contains("__sm_") == true, "\(opened ?? "no such line")")
        #expect(opened?.contains("{ return }") == true, "\(opened ?? "no such line")")
    }

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

    /// The invariant every line number a run reports rests on: a line in the instrumented
    /// file is the same line in the file the author wrote.
    ///
    /// A statement guard is the one shape that can break it, because it is the one shape
    /// that adds text outside an expression - and a newline after it would compile
    /// perfectly, push the whole body down by one, and make every later line number wrong
    /// in a way no compiler would ever mention. This was `written >= original`, which is a
    /// sentence that cannot fail; the perturbation that adds that newline left it green.
    @Test("keeps the file the same number of lines")
    func keepsTheLines() throws {
        let instrumented = try Self.instrument(Self.bodies)
        let before = Self.bodies.split(separator: "\n", omittingEmptySubsequences: false).count
        let after = instrumented.source
            .split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(
            after - instrumented.runtimeLineCount == before,
            "\(before) lines became \(after - instrumented.runtimeLineCount)")
    }
}
