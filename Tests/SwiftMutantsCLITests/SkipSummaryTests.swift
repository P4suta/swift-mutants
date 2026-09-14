// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsCLI

/// What was passed over, gathered by reason rather than scattered by place.
///
/// `list --explain` prints every skip where it is, which is what somebody wants when they
/// are looking at one file. It is not what they want when they are asking a different
/// question - "is this tool ignoring half my package, and on what grounds?" - and that
/// question is the one that decides whether a score means anything.
///
/// Every rule here is about not being able to hide. The reasons are all shown, including
/// the ones that hid nothing, because a reason with a zero beside it is how somebody learns
/// it exists.
@Suite("What was passed over")
struct SkipSummaryTests {

    static func path(_ name: String) -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/\(name).swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func skip(_ reason: SkipReason, hiding: Int, at start: Int = 0) -> Skip {
        guard let span = SourceSpan(start: start, end: start + 1) else {
            fatalError("malformed fixture span")
        }
        return Skip(reason: reason, span: span, candidatesHidden: hiding)
    }

    static func lines(_ skips: [(reason: SkipReason, hiding: Int)]) -> [String] {
        SkipSummary.lines(
            for: skips.enumerated().map {
                (Self.path("A"), Self.skip($1.reason, hiding: $1.hiding, at: $0))
            })
    }

    @Test("counts each reason, and what it hid")
    func countsEachReason() {
        let said = Self.lines([(.arid, 3), (.arid, 2), (.macroExpansion, 1)])
            .joined(separator: "\n")
        #expect(said.contains("arid"))
        #expect(said.contains("2 places"))
        #expect(said.contains("5 mutants"))
        #expect(said.contains("macro-expansion"))
    }

    /// A reason nobody has met is a reason nobody can judge. Showing the whole list, zeroes
    /// included, is how somebody learns that `loop-condition-literal` exists at all.
    @Test("shows every reason there is, including the ones that hid nothing")
    func showsEveryReason() {
        let said = Self.lines([(.arid, 1)]).joined(separator: "\n")
        for reason in SkipReason.allCases {
            #expect(said.contains(reason.rawValue), "it never mentions \(reason.rawValue)")
        }
    }

    /// The busiest first, because that is the one worth arguing about.
    @Test("puts the reason that hid most at the top")
    func mostFirst() throws {
        let said = Self.lines([(.arid, 1), (.macroExpansion, 9)])
        let arid = try #require(said.firstIndex { $0.contains(" arid ") })
        let macro = try #require(said.firstIndex { $0.contains("macro-expansion") })
        #expect(macro < arid)
    }

    /// Ties broken by name, so two runs of the same package say it the same way.
    @Test("breaks a tie the same way every time")
    func stableTies() throws {
        let said = Self.lines([(.arid, 2), (.excluded, 2)])
        let arid = try #require(said.firstIndex { $0.contains(" arid ") })
        let excluded = try #require(said.firstIndex { $0.contains("excluded") })
        #expect(arid < excluded)
    }

    @Test("says plainly when nothing was passed over")
    func nothingSkipped() {
        #expect(SkipSummary.lines(for: []).joined(separator: "\n").contains("nothing"))
    }
}
