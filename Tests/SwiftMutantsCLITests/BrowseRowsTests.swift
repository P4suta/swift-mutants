// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsReport
import SwiftMutantsTUI
import Testing

@testable import SwiftMutantsCLI

/// What a browser is handed.
///
/// The browser itself is tested against rows; this is about which rows it gets, and the
/// answer is the survivors. A killed mutant is not a thing to walk through - whoever reads
/// it already has the test that caught it, which beats anything a browser could show.
@Suite("What a browser is handed")
struct BrowseRowsTests {

    static func report(_ outcomes: [Outcome]) -> RunReport {
        RunReport(
            of: NarrationFixture.outcome(
                results: outcomes.map { outcome in
                    NarrationFixture.result(
                        outcome, tests: outcome == .survived ? [] : ["MathTests/testAdd"])
                }
            ))
    }

    @Test("hands it the survivors and nothing else")
    func survivorsOnly() {
        let rows = BrowseCommand.rows(of: Self.report([.survived, .killed, .survived]))
        #expect(rows.count == 2)
    }

    /// Everything `explain` would say, because that is what somebody opened it for.
    @Test("hands it everything explain would say about one")
    func theWholeStory() throws {
        let rows = BrowseCommand.rows(of: Self.report([.survived]))
        let row = try #require(rows.first)
        #expect(row.identity.count == 64)
        #expect(row.place.contains(".swift"))
        #expect(row.story.contains { $0.contains("no test reaches this") })
    }

    @Test("says nothing to walk through when nothing survived")
    func nothingSurvived() {
        #expect(BrowseCommand.rows(of: Self.report([.killed])).isEmpty)
    }
}
