// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsCache

/// What this tool has kept, and how to stop keeping it.
///
/// A cache exists to be trusted, and the moment somebody stops trusting one is the moment
/// they need to see inside it. There was no way to: the answers live outside the repository
/// under a name that is a digest, which is right - a run must not write into somebody's tree
/// and two packages must not share answers - and it leaves a person who suspects a stale
/// answer with nothing to do but find and delete a directory they were never told about.
///
/// `--cache off` was the whole escape hatch, and it answers a different question. It says
/// "do not use one this time"; it does not say what is in there, how old it is, or how to
/// be rid of it.
///
/// One file per package, so the thing that accumulates is packages. A machine that measured
/// forty repositories last year keeps forty answers files for repositories that may no
/// longer exist - which is what `gc` is for, and why it counts days rather than entries.
@Suite("What the cache is keeping")
struct InventoryTests {

    static func entry(_ name: String, daysAgo: Int, bytes: Int = 1024) -> CacheInventory.Entry {
        CacheInventory.Entry(
            file: URL(filePath: "/cache/\(name)"),
            bytes: bytes,
            modified: Date(timeIntervalSince1970: 1_000_000 - Double(daysAgo) * 86_400)
        )
    }

    static let now = Date(timeIntervalSince1970: 1_000_000)

    /// Older than asked, by the file's own age. Not by anything inside it: an answer
    /// carries no date and giving it one would be a schema change to answer a question the
    /// file's own timestamp already answers.
    @Test("says which of them have not been written to lately")
    func findsTheOldOnes() {
        let kept = [
            Self.entry("a", daysAgo: 1),
            Self.entry("b", daysAgo: 40),
            Self.entry("c", daysAgo: 400),
        ]
        let stale = CacheInventory.stale(kept, olderThan: 30, now: Self.now)
        #expect(stale.map { $0.file.lastPathComponent } == ["b", "c"])
    }

    /// The boundary belongs to the newer side. A cache written exactly thirty days ago is
    /// thirty days old, not thirty-one, and a `gc --days 30` that removed it would be
    /// removing something the person asked to keep.
    @Test("keeps one that is exactly as old as was asked for")
    func theBoundary() {
        #expect(
            CacheInventory.stale([Self.entry("a", daysAgo: 30)], olderThan: 30, now: Self.now)
                .isEmpty)
    }

    /// And nought does not mean all of them, which is the other reading and the dangerous
    /// one. A cache written this instant is not older than nought days, so a mistyped sweep
    /// removes nothing rather than everything - and `clean` is the way to say "all of
    /// mine", which is a different sentence and should look like one.
    @Test("removes nothing for nought days, rather than everything")
    func noughtDays() {
        #expect(
            CacheInventory.stale([Self.entry("a", daysAgo: 0)], olderThan: 0, now: Self.now)
                .isEmpty)
    }

    /// A negative number is not an age. Nothing is removed, because the alternative is
    /// removing everything for a typo.
    @Test("removes nothing for a number that is not an age")
    func negativeDays() {
        #expect(
            CacheInventory.stale([Self.entry("a", daysAgo: 400)], olderThan: -1, now: Self.now)
                .isEmpty)
    }

    /// And it says what it is about to do in the units a person thinks in.
    @Test("says how much is kept, in something a person can read")
    func saysHowMuch() {
        let said = CacheInventory.summary(
            of: [Self.entry("a", daysAgo: 1, bytes: 2_500_000)], now: Self.now)
        #expect(said.contains("1"), "\(said)")
        #expect(said.contains("MB") || said.contains("2.5"), "\(said)")
    }

    /// Nothing kept is not an error. It is every machine before its first run.
    @Test("says so when it is keeping nothing")
    func nothingKept() {
        #expect(CacheInventory.summary(of: [], now: Self.now).lowercased().contains("nothing"))
    }
}
