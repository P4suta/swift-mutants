// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// The tier above `strong`, which until now had nothing in it.
///
/// `all` was a name a project could write in its settings and a row the starter file
/// explained, and it selected exactly what `strong` did. These are the rules it is for:
/// noisier than the tiers below - a constant appears in far more places than an operator -
/// and worth having where a project wants everything.
@Suite("Literals and unary minus")
struct LiteralAndUnaryTests {

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

    /// One either side, which is where an off-by-one lives, and never the literal itself:
    /// `1` replaced by `1` is a mutant that cannot fail.
    @Test("moves an integer literal by one in each direction")
    func movesByOne() {
        #expect(Self.replacements("let n = limit + 3", for: "literal-one-more") == ["4"])
        #expect(Self.replacements("let n = limit + 3", for: "literal-one-less") == ["2"])
    }

    /// Zero has no one-less worth having: `-1` is a different kind of number, and on a
    /// count or an index it is a value the program was never going to see.
    @Test("moves zero upward only")
    func zero() {
        #expect(Self.replacements("let n = limit + 0", for: "literal-one-more") == ["1"])
        #expect(Self.replacements("let n = limit + 0", for: "literal-one-less").isEmpty)
    }

    /// A negation removed, which is the whole of the rule: `-x` becoming `x` is the sign
    /// error every numeric routine has had at least once.
    @Test("removes a unary minus")
    func removesNegation() {
        #expect(Self.replacements("let n = -count", for: "drop-negation") == ["count"])
    }

    /// Never on a literal, where the negation is part of how the number is written and
    /// `literal-one-more` is already asking about the value.
    @Test("leaves the minus on a literal alone")
    func leavesLiteralNegation() {
        #expect(!Self.rules("let n = -1").contains("drop-negation"))
    }

    /// Both are in `all` and neither is below it: a constant appears in far more places
    /// than an operator, and a tier is a trade a project makes rather than a default.
    @Test("is in the tier that says it is, and not below it")
    func tier() {
        let source = "let n = limit + 3"
        #expect(Self.rules(source, profile: .all).contains("literal-one-more"))
        #expect(!Self.rules(source, profile: .strong).contains("literal-one-more"))
        #expect(!Self.rules(source, profile: .balanced).contains("literal-one-more"))
    }

    /// And the tier is no longer empty, which is what the settings file has been saying.
    @Test("gives the top tier something to select")
    func topTierIsNotEmpty() {
        let top = RuleSelection.tiers.first { $0.tier == .all }
        #expect(top?.adds.isEmpty == false, "`all` selects exactly what `strong` does")
    }
}
