// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsTempOwner

/// Who owns a temporary directory, and what becomes of the ones nobody does.
///
/// A run happens inside a copy of somebody's package, and that copy holds a whole build
/// directory - hundreds of megabytes for a package with dependencies. The copy is deleted
/// when the run ends, and a run that does not end - interrupted, killed, crashed - leaves
/// it behind. Nine gigabytes of them accumulated on one machine in one afternoon of
/// developing this tool, which is how the need for this was found.
///
/// Every rule here is about the one mistake that matters: deleting a directory that a live
/// run is working in. So it deletes only what it can prove is abandoned, and leaves
/// everything it cannot read.
@Suite("Owning a temporary directory")
struct TempOwnerTests {

    struct Fixture {
        let parent: URL
        func cleanUp() { try? FileManager.default.removeItem(at: parent) }

        func directory(_ name: String) throws -> URL {
            let made = parent.appending(path: name)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            try Data("something large".utf8).write(to: made.appending(path: "contents"))
            return made
        }
    }

    static func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-owner-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return Fixture(parent: parent)
    }

    /// A pid nothing will ever have: the kernel refuses it, so `kill(pid, 0)` always says
    /// it is gone.
    static let deadOwner: Int32 = 0x7FFF_FFFF

    @Test("writes down who it belongs to")
    func claims() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let mine = try fixture.directory("swift-mutants-mine")

        try TempOwner.claim(mine)
        #expect(TempOwner.owner(of: mine) != nil)
    }

    /// The rule that matters. A directory somebody is working in survives, whatever else
    /// happens.
    @Test("leaves a directory its owner is still running in")
    func leavesTheLiving() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let live = try fixture.directory("swift-mutants-live")
        try TempOwner.claim(live)

        #expect(TempOwner.sweep(in: fixture.parent, besides: nil) == 0)
        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    @Test("removes a directory whose owner is gone")
    func removesTheAbandoned() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let orphan = try fixture.directory("swift-mutants-orphan")
        try TempOwner.claim(orphan, by: Self.deadOwner)

        #expect(TempOwner.sweep(in: fixture.parent, besides: nil) == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    /// Never delete what you did not make. A directory with no marker belongs to somebody
    /// else, whatever it is called.
    @Test("leaves a directory it never claimed")
    func leavesTheUnclaimed() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let stranger = try fixture.directory("swift-mutants-stranger")

        #expect(TempOwner.sweep(in: fixture.parent, besides: nil) == 0)
        #expect(FileManager.default.fileExists(atPath: stranger.path))
    }

    /// And never delete what you cannot read. A marker half-written by a run that died
    /// mid-claim names nobody, and guessing is the one thing this must not do.
    @Test("leaves a directory whose marker it cannot read", arguments: ["", "not a number", "-1"])
    func leavesTheUnreadable(_ marker: String) throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let confusing = try fixture.directory("swift-mutants-confusing")
        try Data(marker.utf8).write(to: confusing.appending(path: TempOwner.markerName))

        #expect(TempOwner.sweep(in: fixture.parent, besides: nil) == 0)
        #expect(FileManager.default.fileExists(atPath: confusing.path))
    }

    /// A directory that is not one of ours by name is not looked at at all. The temporary
    /// directory is shared with the whole machine.
    @Test("looks only at the directories this tool makes")
    func looksOnlyAtItsOwn() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let other = try fixture.directory("somebody-elses-work")
        try TempOwner.claim(other, by: Self.deadOwner)

        #expect(TempOwner.sweep(in: fixture.parent, besides: nil) == 0)
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    /// The run doing the sweeping is never its own victim, even in the moment before it
    /// has claimed anything.
    @Test("never removes the directory it was told to keep")
    func neverItsOwn() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let mine = try fixture.directory("swift-mutants-mine")
        try TempOwner.claim(mine, by: Self.deadOwner)

        #expect(TempOwner.sweep(in: fixture.parent, besides: mine) == 0)
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }

    @Test("clears several at once and says how many")
    func clearsSeveral() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        for name in ["swift-mutants-a", "swift-mutants-b", "swift-mutants-c"] {
            try TempOwner.claim(try fixture.directory(name), by: Self.deadOwner)
        }
        #expect(TempOwner.sweep(in: fixture.parent, besides: nil) == 3)
    }

    /// Nothing there is not a failure. A first run on a clean machine sweeps nothing.
    @Test("sweeps a directory that is not there")
    func nothingThere() {
        #expect(TempOwner.sweep(in: URL(filePath: "/swift-mutants-nowhere"), besides: nil) == 0)
    }
}
