// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// Names one mutation rule, at one version.
///
/// The version is not documentation. It participates in every mutant identity the rule
/// produces, so changing what a rule emits changes the identity of its mutants — which
/// makes the outcome cache miss and any recorded expectation go stale, loudly, instead of
/// a run silently reusing a verdict that was reached about different bytes.
@Suite("Rule identifier")
struct RuleIdentifierTests {

    @Test("renders as name-at-version")
    func rendersCanonically() throws {
        let rule = try #require(RuleIdentifier("add-to-sub", version: 1))
        #expect(rule.rendered == "add-to-sub@1")
        #expect(rule.name == "add-to-sub")
        #expect(rule.version == 1)
    }

    @Test("parses what it renders")
    func parsesItsOwnRendering() throws {
        let rule = try #require(RuleIdentifier("negate-if-condition@3"))
        #expect(rule.name == "negate-if-condition")
        #expect(rule.version == 3)
    }

    /// Rule names appear in configuration, on the command line, in reports and in file
    /// names. One spelling keeps all four agreeing.
    @Test(
        "refuses a name that is not lowercase kebab-case",
        arguments: ["", "Add-To-Sub", "add_to_sub", "add to sub", "add-to-sub-", "-add", "add--to"]
    )
    func refusesIllFormedName(name: String) {
        #expect(RuleIdentifier(name, version: 1) == nil)
    }

    @Test("refuses a version that is not positive", arguments: [0, -1])
    func refusesNonPositiveVersion(version: Int) {
        #expect(RuleIdentifier("add-to-sub", version: version) == nil)
    }

    @Test(
        "refuses a spelling that is not exactly name-at-version",
        arguments: [
            "add-to-sub", "add-to-sub@", "@1", "add-to-sub@1@2", "add-to-sub@x", "add-to-sub@01",
        ]
    )
    func refusesIllFormedSpelling(spelling: String) {
        #expect(RuleIdentifier(spelling) == nil)
    }

    @Test("orders by name, then by version")
    func ordering() throws {
        let rules = try ["b@1", "a@2", "a@1"].map { try #require(RuleIdentifier($0)) }
        #expect(rules.sorted().map(\.rendered) == ["a@1", "a@2", "b@1"])
    }

    @Test("encodes as its rendered spelling")
    func codableRoundTrip() throws {
        let rule = try #require(RuleIdentifier("add-to-sub", version: 1))
        let json = try JSONTestSupport.canonicalJSON(of: ["r": rule])
        #expect(json == #"{"r":"add-to-sub@1"}"#)
        #expect(try JSONTestSupport.decode([String: RuleIdentifier].self, from: json)["r"] == rule)
    }

    @Test("refuses to decode a spelling it would have refused to build")
    func refusesToDecodeIllFormed() {
        #expect(throws: (any Error).self) {
            try JSONTestSupport.decode(RuleIdentifier.self, from: #""add-to-sub""#)
        }
    }
}
