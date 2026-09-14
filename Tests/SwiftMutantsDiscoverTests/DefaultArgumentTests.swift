// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// A default argument value is a place a guard cannot go.
///
/// Swift refuses a default argument value that references a private declaration, and the
/// runtime this tool appends is private by design - it has to be, or two instrumented
/// files in one module would collide. So a guard in a default argument produces
///
///     global function '__sm_6016143c277a' is private and cannot be referenced from a
///     default argument value
///
/// which is not about any mutant's *content* and therefore lands nowhere attribution can
/// place it. A run then falls to halving the whole catalogue, which is the expensive path,
/// for a mutant that could never have compiled.
///
/// Found by running swift-mutants on swift-mutants: `outputLimit: Int = 1 << 20`.
///
/// Recorded as a skip rather than dropped, because nothing here is ever dropped in
/// silence: `list --explain` says how many this cost and where.
@Suite("Default arguments")
struct DefaultArgumentTests {

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func discover(_ source: String) -> FileDiscovery {
        Discover.candidates(in: source, at: Self.path())
    }

    @Test("passes over an expression in a default argument")
    func skipsTheDefault() {
        let found = Self.discover("func f(_ limit: Int = 1 << 20) { _ = limit }")
        #expect(found.candidates.isEmpty)
        #expect(found.skips.map(\.reason) == [.defaultArgument])
    }

    /// The count is the point: "this cost you two" is an answer, "some were passed over"
    /// is not.
    @Test("counts what it passed over")
    func countsThem() {
        let found = Self.discover("func f(_ limit: Int = 1 << 20 + 3) { _ = limit }")
        #expect(found.skips.first?.candidatesHidden == 2)
    }

    /// Only the default. The body beside it is ordinary code and stays mutable.
    @Test("leaves the rest of the declaration alone")
    func onlyTheDefault() {
        let found = Self.discover(
            """
            func f(_ limit: Int = 1 << 20, _ a: Int, _ b: Int) -> Bool {
                return a < b
            }
            """
        )
        #expect(found.candidates.map(\.rule.name) == ["lt-to-le"])
        #expect(found.skips.map(\.reason) == [.defaultArgument])
    }

    @Test(
        "passes over a default wherever one is written",
        arguments: [
            "func f(_ a: Int = 1 + 2) { _ = a }",
            "struct S { init(a: Int = 1 + 2) { _ = a } }",
            "struct S { func m(a: Int = 1 + 2) { _ = a } }",
            "struct S { subscript(a: Int = 1 + 2) -> Int { a } }",
        ])
    func everywhere(source: String) {
        let found = Self.discover(source)
        #expect(found.candidates.isEmpty, "\(found.candidates.map(\.rule.name))")
        #expect(found.skips.contains { $0.reason == .defaultArgument })
    }

    /// The same syntax spells a variable's initial value, which is ordinary code in an
    /// ordinary place and holds a great many of a package's mutants. Passing those over
    /// would be a silent, enormous loss.
    @Test(
        "leaves an ordinary initial value mutable",
        arguments: [
            "let x = 1 << 20",
            "var x = 1 + 2",
            "struct S { let x = 1 + 2 }",
            "struct S { static let x = 1 + 2 }",
            "func f() { let x = 1 + 2; _ = x }",
        ])
    func ordinaryInitialisers(source: String) {
        let found = Self.discover(source)
        #expect(!found.candidates.isEmpty, "nothing found in: \(source)")
        #expect(!found.skips.contains { $0.reason == .defaultArgument })
    }

    /// Recorded even when it held nothing, the way every other skip is: the record is of
    /// the rule having matched, which is what says whether a rule is too broad.
    @Test("records a default with nothing in it, hiding nothing")
    func plainDefault() {
        let found = Self.discover("func f(_ a: Int = 0) { _ = a }")
        #expect(
            found.skips.map { "\($0.reason.rawValue):\($0.candidatesHidden)" }
                == ["default-argument:0"])
    }
}
