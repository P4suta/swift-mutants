// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsInstrument

/// What a guard around a skipped statement actually says.
///
/// The condition is the other way up from every other guard here, and that is the whole of
/// the rule: a body's guard does its work when the mutant is *awake*, and a statement's
/// guard does its work when it is *asleep*, the mutation being that the statement does not
/// run.
///
/// No compiler can see this. `if g { s }` and `if !g { s }` both build, and the difference
/// only appears at run time - as an instrumented baseline where nothing runs, which is a
/// long way from here and an expensive place to find out. A perturbation that dropped the
/// `!` left every compile gate green.
@Suite("Which way up a statement's guard is")
struct StatementSkipTests {

    static func instrumented(_ source: String) throws -> String {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        return try Instrument.file(
            source,
            discovery: Discover.candidates(in: source, at: path, selecting: mutation)
        ).source
    }

    static let source = """
        func record(_ n: Int) {}
        func plain() {
            record(1)
            record(2)
        }
        """

    /// Asleep is the ordinary state: with no mutant awake every statement runs, which is
    /// what makes the instrumented tree behave like the one the author wrote.
    @Test("runs the statement when the mutant is asleep")
    func invertedForSkipping() throws {
        let written = try Self.instrumented(Self.source)
        #expect(written.contains("if !__sm_"), "\(written.prefix(400))")
        #expect(!written.contains("{ if __sm_"), "a statement's guard is never the right way up")
    }

    /// And a body's guard is the other way, in the same file, so the two cannot be confused
    /// for one convention applied twice.
    @Test("replaces the body when the mutant is awake")
    func uprightForBodies() throws {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        mutation.extreme = true
        let written = try Instrument.file(
            "func total() -> Int {\n    let a = 1\n    return a + 1\n}",
            discovery: Discover.candidates(
                in: "func total() -> Int {\n    let a = 1\n    return a + 1\n}",
                at: path,
                selecting: mutation)
        ).source
        #expect(written.contains("{ if __sm_"), "\(written.prefix(400))")
    }
}
