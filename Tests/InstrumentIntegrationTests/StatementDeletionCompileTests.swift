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

            // Blocks whose one statement is safe to skip, because nothing downstream needs
            // them to have run and falling out of them is what they do anyway.
            func handling() {
                do {
                    try risky()
                } catch {
                    record(1)
                }
            }

            func conditional(_ flag: Bool) {
                if flag {
                    record(1)
                }
                while n > 0 {
                    n -= 1
                }
            }

            func switching(_ n: Int) {
                switch n {
                case 0:
                    record(0)
                default:
                    record(1)
                }
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

    /// A block of one statement is skippable when nothing downstream needs it to have run.
    /// A `catch` that does nothing is one of the best mutants there is - it asks whether
    /// anything tests that errors are handled at all - and the rule refused it for a reason
    /// that is only true of function bodies and `guard`.
    @Test(
        "skips the only statement of a block that may fall out of it",
        arguments: [
            "func f() throws {\n    do {\n        try g()\n    } catch {\n        log()\n    }\n}",
            "func f(_ flag: Bool) {\n    if flag {\n        log()\n    }\n}",
            "func f(_ xs: [Int]) {\n    for x in xs {\n        record(x)\n    }\n}",
        ]
    )
    func skipsLoneStatements(source: String) throws {
        let whole = "func g() throws {}\nfunc log() {}\nfunc record(_ n: Int) {}\n" + source
        #expect(!(try Self.deletions(whole)).isEmpty, "\(whole)")
        let instrumented = try Self.instrument(whole)
        let said = try InlinableTests.compile(["Subject.swift": instrumented.source])
        #expect(said.exitCode == 0, "\(said.text)")
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
