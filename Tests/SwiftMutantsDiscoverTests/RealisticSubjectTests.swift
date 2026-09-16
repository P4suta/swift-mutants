// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// What discovery does to a file that looks like something somebody wrote.
///
/// The individual rules are tested on one-line fixtures, which is where a rule's meaning is
/// clearest. This is the other half: a file where the rules interact - a logging call beside
/// real logic, a suppression comment, precedence that decides what a guard wraps - because
/// that is the only place their *interaction* is visible.
@Suite("A realistic subject")
struct RealisticSubjectTests {

    static let source = """
        struct Header {
            func isValid(_ length: Int, _ limit: Int, _ strict: Bool) -> Bool {
                logger.debug("checking \\(length) <= \\(limit)")
                // swift-mutants disable next-line boolean-literal: the default is not behaviour
                let lenient = true
                return length <= limit && (strict || lenient)
            }
        }
        """

    static func discovery() -> FileDiscovery {
        guard let path = WorkspaceRelativePath("Sources/Header.swift") else {
            fatalError("malformed fixture path")
        }
        return Discover.candidates(in: Self.source, at: path)
    }

    @Test("finds the logic and leaves the rest")
    func findsTheLogic() {
        // The operators, not the whole catalogue. Every statement in this subject is also a
        // site for statement deletion, and a test that listed both would be a test about
        // every rule this tool will ever have rather than about the logic in this file.
        let found = Self.discovery().candidates
            .filter { !$0.rule.name.hasPrefix("skip-") }
            .map { "\($0.rule.name) \($0.original)->\($0.replacement)" }
        #expect(
            found.sorted() == [
                "and-keep-lhs length <= limit && (strict || lenient)->length <= limit",
                "and-keep-rhs length <= limit && (strict || lenient)->(strict || lenient)",
                "and-to-or &&->||",
                "le-to-lt <=-><",
                "or-keep-lhs strict || lenient->strict",
                "or-keep-rhs strict || lenient->lenient",
                "or-to-and ||->&&",
            ]
        )
    }

    @Test("names where each edit lives")
    func namesTheDeclaration() {
        #expect(
            Self.discovery().candidates.allSatisfy { $0.enclosingDeclaration == "Header.isValid" }
        )
    }

    /// `a <= b && (c || d)` groups as `(a <= b) && (c || d)`, so the guard around the
    /// comparison wraps only the comparison and the one around the connective wraps the
    /// whole condition. That is only knowable once precedence has been resolved.
    @Test("wraps what precedence says, not what the line looks like")
    func wrapsWhatPrecedenceSays() {
        let bytes = Array(Self.source.utf8)
        // The operators, for the same reason as above: a statement guard wraps a statement,
        // which is a fact about a different rule.
        let wrapped = Self.discovery().candidates
            .filter { !$0.rule.name.hasPrefix("skip-") }
            .map { String(decoding: bytes[$0.guardSpan.start..<$0.guardSpan.end], as: UTF8.self) }
        // Three sites, not seven: the prunes at a connective share the site its swap has,
        // because they are alternatives at one expression rather than sites of their own.
        #expect(
            Set(wrapped) == [
                "length <= limit",
                "length <= limit && (strict || lenient)",
                "strict || lenient",
            ]
        )
    }

    /// The logging call hides nothing, and the record says so.
    ///
    /// The `<=` inside its string is text rather than an operator, so there was never a
    /// candidate there. A skip that hid nothing is still worth recording: it says the rule
    /// matched, which is what a reader checking whether a rule is too broad needs to see.
    @Test("says what it passed over and how much, including nothing")
    func saysWhatItPassedOver() {
        let skips = Self.discovery().skips.map { "\($0.reason.rawValue):\($0.candidatesHidden)" }
        #expect(skips == ["arid:0", "disabled-by-comment:1"])
    }

    /// Every span names the bytes it says it does. Everything downstream - splicing, the
    /// diff in a report, the identity of the mutant - is wrong if this is.
    @Test("names the bytes it says it does")
    func spansAreExact() {
        let bytes = Array(Self.source.utf8)
        for candidate in Self.discovery().candidates {
            let slice = String(
                decoding: bytes[candidate.span.start..<candidate.span.end],
                as: UTF8.self
            )
            #expect(slice == candidate.original)
            #expect(candidate.guardSpan.contains(candidate.span))
        }
    }
}
