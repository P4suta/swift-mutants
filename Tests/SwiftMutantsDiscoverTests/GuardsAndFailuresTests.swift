// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// The last two families the plan asks for: a pattern's extra condition, and a failure
/// that is quietly turned into nothing.
///
/// Both are places Swift lets an author write something easy to stop testing. A `where`
/// clause is a condition nobody looks at twice, and `try?` is the one line in a program
/// whose whole purpose is that a failure stops being a failure.
@Suite("Pattern guards and swallowed failures")
struct GuardsAndFailuresTests {

    static func rules(_ source: String, profile: Configuration.Profile = .all) -> [String] {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = profile
        return Discover.candidates(in: source, at: path, selecting: mutation)
            .candidates.map(\.rule.name)
    }

    static func replacements(_ source: String, for rule: String) -> [String] {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        return Discover.candidates(in: source, at: path, selecting: mutation)
            .candidates.filter { $0.rule.name == rule }.map(\.replacement)
    }

    static let switching = """
        func classify(_ k: Kind, _ n: Int) -> String {
            switch k {
            case .a where n > 0: return "pos"
            case .a: return "a"
            case .b: return "b"
            }
        }
        """

    /// Always matching asks whether the condition is load-bearing; never matching asks
    /// whether anything reaches the case at all. Two different holes.
    @Test("makes a case's extra condition always and never match")
    func switchWhere() {
        #expect(Self.replacements(Self.switching, for: "pattern-always-matches") == ["true"])
        #expect(Self.replacements(Self.switching, for: "pattern-never-matches") == ["false"])
    }

    /// A `where` on a loop and on a `catch` is the same clause in a different place, and
    /// the same two questions.
    @Test("finds the clause wherever it is written")
    func everyWhere() {
        let loop = Self.rules("func f(_ xs: [Int]) { for x in xs where x > 0 { use(x) } }")
        #expect(loop.contains("pattern-always-matches"), "\(loop)")
        let caught = Self.rules(
            "func f() { do { try g() } catch let e as E where e.fatal { log(e) } }")
        #expect(caught.contains("pattern-always-matches"), "\(caught)")
    }

    /// `try?` is the one line in a program whose whole purpose is that a failure stops
    /// being a failure. Made always to fail, it asks whether anything tests the path the
    /// author wrote it for - and it keeps the type, `try? f()` and `nil` both being the
    /// optional the expression already was.
    @Test("makes an optional try fail every time")
    func optionalTry() {
        #expect(Self.replacements("let v = try? risky()", for: "try-optional-fails") == ["nil"])
    }

    /// Never a plain `try`, which propagates rather than swallowing: there is nothing there
    /// to turn into nothing, and `nil` is not its type.
    @Test("leaves a try that propagates alone")
    func plainTry() {
        #expect(!Self.rules("func f() throws { try risky() }").contains("try-optional-fails"))
    }

    /// Two rules can arrive at the same bytes, and the catalogue holds one of them. `where
    /// true` on a loop is a boolean literal *and* a pattern's condition, so the literal rule
    /// and the pattern rule both offer `false` over the same span - which is two processes,
    /// two lines in a report, and one question.
    ///
    /// Found by this family: nothing collided until a rule arrived that looks at a
    /// condition somebody else's rule was already looking at.
    @Test("offers one mutant per edit, not one per rule that reached it")
    func oneMutantPerEdit() {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        let found = Discover.candidates(
            in: "func f(_ xs: [Int]) { for x in xs where true { use(x) } }",
            at: path,
            selecting: mutation
        ).candidates
        let edits = found.map { "\($0.span.start)..<\($0.span.end)->\($0.replacement)" }
        #expect(edits.count == Set(edits).count, "\(edits)")
    }

    /// And the one it keeps is the same one every time, because a mutant's identity is its
    /// rule: a catalogue that named this differently on Tuesday would invalidate every
    /// cached answer about it.
    @Test("keeps the same one every time")
    func deterministically() {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        let source = "func f(_ xs: [Int]) { for x in xs where true { use(x) } }"
        let once = Discover.candidates(in: source, at: path, selecting: mutation)
            .candidates.map(\.rule.name)
        let again = Discover.candidates(in: source, at: path, selecting: mutation)
            .candidates.map(\.rule.name)
        #expect(once == again)
        #expect(once.contains("pattern-never-matches"), "\(once)")
        #expect(!once.contains("true-to-false"), "\(once)")
    }

    /// Both are in `balanced`: a `where` clause and a swallowed failure are as ordinary as
    /// a comparison, and a survivor in either is as plain a hole.
    @Test("is in the tier that says it is")
    func tiers() {
        for family in ["pattern-matching", "error-handling"] {
            #expect(RuleSelection.everyFamily.contains(family), "\(family)")
        }
        #expect(
            Self.rules(Self.switching, profile: .balanced).contains("pattern-always-matches"))
    }
}
