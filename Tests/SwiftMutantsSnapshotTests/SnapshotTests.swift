// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsSnapshot

/// The first invariant: the tree a run was pointed at is never written to.
///
/// Discovery reads it; every build, edit and test happens inside a disposable copy. That is
/// what makes it safe to point this tool at a repository somebody is in the middle of
/// working in, and what makes a failed run leave a working tree exactly as it found it.
@Suite("Snapshot")
struct SnapshotTests {

    /// Builds a small tree to copy.
    static func sourceTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-source-\(UUID().uuidString)")
        for (path, contents) in files {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
        return root
    }

    static func destination() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-snap-\(UUID().uuidString)")
    }

    @Test("copies the tree and lists what it copied, in one order")
    func copiesAndLists() throws {
        let source = try Self.sourceTree([
            "Sources/B.swift": "second",
            "Sources/A.swift": "first",
            "Package.swift": "manifest",
        ])
        let target = Self.destination()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }

        let snapshot = try Snapshot.create(of: source, at: target)
        #expect(
            snapshot.manifest.entries.map(\.path.rendered) == [
                "Package.swift", "Sources/A.swift", "Sources/B.swift",
            ]
        )
        #expect(
            try String(contentsOf: target.appending(path: "Sources/A.swift"), encoding: .utf8)
                == "first"
        )
    }

    /// Two machines copying the same tree have to agree about what they copied, so the
    /// digest cannot depend on the order the filesystem handed the entries over.
    @Test("digests the same tree the same way")
    func digestIsStable() throws {
        let files = ["a.swift": "one", "b/c.swift": "two", "b/d.swift": "three"]
        let first = try Self.sourceTree(files)
        let second = try Self.sourceTree(files)
        let firstTarget = Self.destination()
        let secondTarget = Self.destination()
        defer {
            for url in [first, second, firstTarget, secondTarget] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let one = try Snapshot.create(of: first, at: firstTarget)
        let other = try Snapshot.create(of: second, at: secondTarget)
        #expect(one.manifest.digest == other.manifest.digest)
    }

    @Test("digests differently when a byte differs")
    func digestFollowsTheContents() throws {
        let first = try Self.sourceTree(["a.swift": "one"])
        let second = try Self.sourceTree(["a.swift": "ONE"])
        let firstTarget = Self.destination()
        let secondTarget = Self.destination()
        defer {
            for url in [first, second, firstTarget, secondTarget] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        #expect(
            try Snapshot.create(of: first, at: firstTarget).manifest.digest
                != Snapshot.create(of: second, at: secondTarget).manifest.digest
        )
    }

    /// Refused, not skipped. A link that leaves the tree makes the copy a copy of something
    /// else, and one that stays inside makes two paths one file - so an edit to a mutant
    /// would silently change a second place. Neither is a thing to discover halfway through
    /// a run.
    @Test("refuses a symbolic link rather than following or skipping it")
    func refusesASymbolicLink() throws {
        let source = try Self.sourceTree(["a.swift": "one"])
        let target = Self.destination()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "link.swift"),
            withDestinationURL: source.appending(path: "a.swift")
        )

        do {
            _ = try Snapshot.create(of: source, at: target)
            Issue.record("the link was accepted")
        } catch let failure as SnapshotError {
            #expect(failure.description.contains("link.swift"), "\(failure)")
            #expect(failure.description.contains("link"), "\(failure)")
        }
    }

    @Test("refuses a file that is not a file")
    func refusesASpecialFile() throws {
        let source = try Self.sourceTree(["a.swift": "one"])
        let target = Self.destination()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        // mkfifo is a C call, and -strict-memory-safety wants that said rather than
        // hidden. Making a pipe is the only way to get a file that is not a file.
        #expect(unsafe mkfifo(source.appending(path: "pipe").path, 0o644) == 0)

        #expect(throws: SnapshotError.self) { try Snapshot.create(of: source, at: target) }
    }

    /// Excluded because copying them is pointless and because the report directory grows
    /// *while* the run digests the tree, which would make a run report drift it caused
    /// itself.
    @Test("leaves out what a copy has no use for, at every level it appears")
    func excludesTheUnneeded() throws {
        let source = try Self.sourceTree([
            "a.swift": "one",
            ".git/config": "git",
            ".build/debug/thing": "built",
            "Plugins/Nested/.build/debug/thing": "a package inside a package",
            "reports/mutation/mutation.json": "report",
            // Only the root report directory is excluded: a deeper one may be source.
            "Sources/Reporting/reports/Writer.swift": "source",
        ])
        let target = Self.destination()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }

        let snapshot = try Snapshot.create(of: source, at: target)
        #expect(
            snapshot.manifest.entries.map(\.path.rendered) == [
                "Sources/Reporting/reports/Writer.swift", "a.swift",
            ]
        )
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: ".git").path))
    }

    /// A test that writes into the package directory it runs in would make every later
    /// mutant a measurement of a different program. The gate is a second digest.
    @Test(
        "notices a file that changed, appeared or vanished after it was copied",
        arguments: ["changed", "appeared", "vanished"]
    )
    func noticesDrift(kind: String) throws {
        let source = try Self.sourceTree(["a.swift": "one", "b.swift": "two"])
        let target = Self.destination()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let snapshot = try Snapshot.create(of: source, at: target)
        #expect(try snapshot.drift().isEmpty)

        switch kind {
        case "changed":
            try Data("edited".utf8).write(to: target.appending(path: "a.swift"))
        case "appeared":
            try Data("new".utf8).write(to: target.appending(path: "c.swift"))
        default:
            try FileManager.default.removeItem(at: target.appending(path: "b.swift"))
        }
        #expect(!(try snapshot.drift().isEmpty), "\(kind) went unnoticed")
    }

    /// The whole point.
    @Test("does not touch the tree it copied")
    func leavesTheSourceAlone() throws {
        let source = try Self.sourceTree(["a.swift": "one", "b/c.swift": "two"])
        let target = Self.destination()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let before = try Snapshot.create(of: source, at: target).manifest.digest

        try Data("edited in the copy".utf8).write(to: target.appending(path: "a.swift"))

        let second = Self.destination()
        defer { try? FileManager.default.removeItem(at: second) }
        #expect(try Snapshot.create(of: source, at: second).manifest.digest == before)
    }

    @Test("refuses to copy over something that is already there")
    func refusesAnOccupiedDestination() throws {
        let source = try Self.sourceTree(["a.swift": "one"])
        let target = Self.destination()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("somebody else's".utf8).write(to: target.appending(path: "notes.txt"))

        #expect(throws: SnapshotError.self) { try Snapshot.create(of: source, at: target) }
    }

    @Test("copies an empty tree without complaint")
    func emptyTree() throws {
        let source = try Self.sourceTree([:])
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let target = Self.destination()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let snapshot = try Snapshot.create(of: source, at: target)
        #expect(snapshot.manifest.entries.isEmpty)
        #expect(try snapshot.drift().isEmpty)
    }
}
