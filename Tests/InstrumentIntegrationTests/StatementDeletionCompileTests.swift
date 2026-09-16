// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsInstrument

/// The compiler's opinion of a statement that does not run.
///
/// Written before the rule was, because every design error in the last four families was
/// found by a compiler and by nothing else. A statement is the richest site there is: it
/// can bind a name the rest of the block needs, it can be the one thing keeping a `guard`
/// from falling through, it can be an implicit return dressed as a call.
///
/// So this fixture is the list of things that must still compile when one of them is
/// wrapped in a guard, and the list of things the rule must therefore not offer.
@Suite("Compiling a statement that does not run", .tags(.integration))
struct StatementDeletionCompileTests {

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

    /// Every shape a statement can take that this rule is allowed to touch.
    static let source = """
        func record(_ n: Int) {}
        func risky() throws {}
        func slow() async {}

        final class Box {
            var n = 0
            var log: [Int] = []

            func plain() {
                record(1)
                record(2)
            }

            func assigning(_ m: Int) {
                n = m
                n += 1
                log.append(m)
            }

            func throwing() throws {
                try risky()
                record(n)
            }

            func awaiting() async {
                await slow()
                record(n)
            }

            func branching(_ flag: Bool) {
                if flag {
                    record(1)
                } else {
                    record(2)
                }
                for i in 0..<3 {
                    record(i)
                }
            }

            func guarding(_ x: Int?) -> Int {
                guard let x else { return 0 }
                record(x)
                return x
            }
        }
        """

    @Test("compiles every statement it is allowed to wrap")
    func compiles() throws {
        let instrumented = try Self.instrument(Self.source)
        let said = try InlinableTests.compile(["Subject.swift": instrumented.source])
        #expect(said.exitCode == 0, "\(said.text)")
    }

    /// The premise. Without statements actually wrapped, the above compiles an ordinary
    /// file and says nothing about this rule.
    @Test("wraps the statements it is about")
    func theStatementsAreWrapped() throws {
        let found = try Self.deletions(Self.source)
        #expect(found.count >= 10, "\(found.map(\.original))")
    }

    /// The line count, which every line number a run reports rests on. A wrap puts text on
    /// the statement's first line and its last, and nothing in between.
    @Test("keeps the file the same number of lines")
    func keepsTheLines() throws {
        let instrumented = try Self.instrument(Self.source)
        let before = Self.source.split(separator: "\n", omittingEmptySubsequences: false).count
        let after = instrumented.source
            .split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(after - instrumented.runtimeLineCount == before)
    }

    /// The things the rule must not offer, each for a reason no compiler would forgive.
    ///
    /// A binding the rest of the block uses; the only statement keeping a `guard` from
    /// falling through; and a single-expression body, where the "statement" is the return
    /// value and not a statement at all.
    @Test(
        "does not offer a statement that cannot be skipped",
        arguments: [
            "func f() -> Int {\n    let a = 1\n    return a\n}",
            "func f(_ x: Int?) -> Int {\n    guard let x else { fatalError() }\n    return x\n}",
            "func f() -> Int { compute() }\nfunc compute() -> Int { 1 }",
            "func f() -> Int {\n    var a = 0\n    a += 1\n    return a\n}",
        ]
    )
    func refusesTheUnskippable(source: String) throws {
        let instrumented = try Self.instrument(source)
        let said = try InlinableTests.compile(["Subject.swift": instrumented.source])
        #expect(said.exitCode == 0, "\(said.text)")
    }

    static func deletions(_ source: String) throws -> [Candidate] {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        return Discover.candidates(in: source, at: path, selecting: mutation)
            .candidates.filter { $0.rule.name.hasPrefix("skip-") }
    }
}
