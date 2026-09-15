// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// A project's own mutant that has nothing to anchor to.
///
/// Code moved and the row stopped testing anything. Silence here is the failure this tool
/// exists to prevent, one level up: somebody carries on believing they have coverage they
/// do not, and believes it *specifically about the code they just changed*, which is the
/// worst possible moment to be wrong about it.
///
/// So it is carried rather than counted. Somebody who had done this by hand for 290 rows
/// hit ten stale anchors in one session of refactoring - four when they split a file, four
/// more when they moved an extension, one when they broke up an expression - and every one
/// was a row that had silently stopped testing anything. The message that made those
/// two-minute fixes rather than hunts was the one that said *which* row, by what it says:
/// "hold frames until the memory runs out" tells somebody instantly what moved. A span
/// tells them nothing and a digest less than that.
@Suite("A project's own mutant with nothing to anchor to")
struct UnanchoredTests {

    static let source = """
        func rank(_ entries: [Int]) -> [Int] {
            let wrong = entries.filter { $0 < 0 }
            return wrong.sorted()
        }
        """

    static func discovery(_ rows: [CustomMutant]) -> FileDiscovery {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return Discover.candidates(in: Self.source, at: path, custom: rows)
    }

    static func row(_ find: String, _ reason: String) -> CustomMutant {
        CustomMutant(find: find, replace: "x", reason: reason)
    }

    @Test("carries the row that could not be anchored, and what it says")
    func carriesTheRow() throws {
        let found = Self.discovery(
            [Self.row("entries.deduplicated()", "hold frames until the memory runs out")])
        let stale = try #require(found.unanchored.first)
        #expect(stale.row.reason == "hold frames until the memory runs out")
        #expect(stale.row.find == "entries.deduplicated()")
    }

    /// The count, because it is what tells the two failures apart: none is code that moved,
    /// more than one is a too-short anchor, and they want different fixes.
    @Test("says how many times the anchor was there")
    func saysTheCount() throws {
        #expect(
            Self.discovery([Self.row("entries.deduplicated()", "gone")]).unanchored.first?
                .occurrences == 0)
        #expect(Self.discovery([Self.row("wrong", "twice")]).unanchored.first?.occurrences == 2)
    }

    @Test("carries nothing when every row anchored")
    func nothingWhenFine() {
        #expect(Self.discovery([Self.row("wrong.sorted()", "fine")]).unanchored.isEmpty)
    }

    /// Every one of them, not the first. A project fixing ten after a refactor wants the
    /// list, not ten runs.
    @Test("carries every row that could not be anchored")
    func carriesAllOfThem() {
        let found = Self.discovery([
            Self.row("gone.one()", "first"),
            Self.row("gone.two()", "second"),
            Self.row("wrong.sorted()", "fine"),
        ])
        #expect(found.unanchored.count == 2)
        #expect(Set(found.unanchored.map(\.row.reason)) == ["first", "second"])
    }

    /// And a skip beside it, so the counts a listing prints still add up.
    @Test("counts it among the skips as well")
    func alsoASkip() {
        let found = Self.discovery([Self.row("entries.deduplicated()", "gone")])
        #expect(found.skips.contains { $0.reason == .customAnchorNotFound })
        #expect(found.unanchored.count == 1)
    }
}
