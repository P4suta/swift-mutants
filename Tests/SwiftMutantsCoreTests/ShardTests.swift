// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// Splitting a catalogue across machines.
///
/// A mutation run is embarrassingly parallel and the only thing stopping it from using ten
/// machines is agreeing on who does what. Agreement without communication needs the split
/// to be a function of the mutant alone - not of the order it was found in, not of how many
/// there are, not of which files were changed.
///
/// The identity is already that function: content-addressed, stable across runs, and
/// uniform enough to divide by. Everything here follows from using it.
@Suite("Shards")
struct ShardTests {

    static func shard(_ index: Int, of count: Int) -> Shard? { Shard(index, of: count) }

    static func digest(_ name: String) -> Digest { Digest.of(name) }

    @Test("refuses a split that is not one")
    func refusesNonsense() {
        #expect(Self.shard(0, of: 3) == nil)
        #expect(Self.shard(4, of: 3) == nil)
        #expect(Self.shard(1, of: 0) == nil)
        #expect(Self.shard(-1, of: 3) == nil)
    }

    @Test("accepts a split that is one")
    func acceptsASplit() {
        #expect(Self.shard(1, of: 3) != nil)
        #expect(Self.shard(3, of: 3) != nil)
        #expect(Self.shard(1, of: 1) != nil)
    }

    /// The property everything rests on: every mutant belongs to exactly one shard, and
    /// which one does not depend on anything but the mutant.
    @Test("gives every mutant to exactly one shard")
    func everyMutantOnce() {
        let names = (0..<200).map { "mutant-\($0)" }
        for name in names {
            let owners = (1...4).filter { Self.shard($0, of: 4)?.holds(Self.digest(name)) == true }
            #expect(owners.count == 1, "\(name) belongs to \(owners)")
        }
    }

    /// One machine means one shard holding everything, which is what a run without the flag
    /// has to behave like.
    @Test("gives everything to the only shard there is")
    func oneShardHoldsAll() {
        let shard = Self.shard(1, of: 1)
        #expect((0..<50).allSatisfy { shard?.holds(Self.digest("m\($0)")) == true })
    }

    /// Ten machines are only worth having if they do about a tenth each. A split that put
    /// nine tenths on one of them would be a split that saved nothing.
    @Test("divides a catalogue roughly evenly")
    func roughlyEven() {
        let names = (0..<1000).map { Self.digest("mutant-\($0)") }
        let sizes = (1...4).map { index in
            names.count { Self.shard(index, of: 4)?.holds($0) == true }
        }
        #expect(sizes.reduce(0, +) == 1000)
        for size in sizes { #expect(size > 150 && size < 350, "\(sizes)") }
    }

    /// Two machines must agree without talking to each other, and they will only agree if
    /// the answer depends on nothing but the mutant.
    @Test("says the same thing every time it is asked")
    func deterministic() {
        let digest = Self.digest("mutant-7")
        let first = (1...5).first { Self.shard($0, of: 5)?.holds(digest) == true }
        #expect(first == (1...5).first { Self.shard($0, of: 5)?.holds(digest) == true })
    }

    /// And it does not depend on where the mutant was in the queue, which is what would
    /// happen if the split were by position: adding one mutant to a file would move every
    /// mutant after it to a different machine, and every cached answer with it.
    @Test("does not move a mutant because another one appeared")
    func stableUnderGrowth() {
        let digest = Self.digest("mutant-7")
        let before = (1...3).first { Self.shard($0, of: 3)?.holds(digest) == true }
        // A larger catalogue changes nothing about this mutant.
        _ = (0..<100).map { Self.digest("new-\($0)") }
        #expect(before == (1...3).first { Self.shard($0, of: 3)?.holds(digest) == true })
    }

    @Test("says what it is, for a report to carry")
    func describesItself() throws {
        let shard = try #require(Self.shard(2, of: 5))
        #expect(shard.index == 2)
        #expect(shard.count == 5)
        #expect(shard.description == "2/5")
    }
}
