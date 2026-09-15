// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCLI

/// Compiles left behind by a run that is not running any more.
///
/// `swift-mutants` puts its children in a process group of their own, so that a Ctrl-C at
/// the terminal does not take a compiler down in the middle of writing a module. The cost of
/// that isolation is that a `swift-mutants` which is killed leaves its compiles running, and
/// the deadline that would have stopped them dies with the parent.
///
/// Reaping them on a signal is not built: it needs a preallocated lock-free registry, and a
/// careless version is worse than the leak because a process id is reused. That decision is
/// written down in a commit message, and the person who meets a compiler that has been
/// running for five hours is not reading commit messages. So `doctor` says.
///
/// Measured: a `swift-frontend` from an interrupted run of this tool's own integration tier
/// spent **five hours and seventeen minutes** on one file, on a machine whose owner could
/// not see why it was busy.
///
/// Read out of `ps` rather than out of anything this tool kept, because the run that would
/// have kept it is the run that is gone.
@Suite("Compiles a run left behind")
struct StrayCompileTests {

    /// Two of this tool's compiles and two of somebody else's, in the format `ps` prints.
    ///
    /// The one that has been there longest is written *second*, deliberately. `ps` prints
    /// in whatever order it likes, and a fixture whose oldest entry happened to be first
    /// would pass whether the ordering existed or not - which is what the first version of
    /// this did, and removing the sort left it green.
    static let listing = """
          PID     ELAPSED COMMAND
            1 01-23:39:24 /sbin/launchd
        12979    00:06 /usr/bin/swift-driver --driver-mode=swiftc -emit-sil /var/folders/x/T/swift-mutants-D93AB43C-5AF6-4A55-848E-A5C8D2F60460/tree/Sources/A/B.swift
        45566 05:17:41 /usr/bin/swift-frontend -frontend -c /var/folders/x/T/swift-mutants-0753FAD1-1111-2222-3333-444455556666/tree/Sources/Core/SHA256.swift
        13031  1:02:03 /usr/bin/swiftc -typecheck /Users/someone/projects/ordinary/Sources/A.swift
        """

    @Test("finds only the compiles working in one of this tool's trees")
    func findsOnlyOurs() {
        let found = StrayCompiles.reading(Self.listing)
        #expect(found.map(\.pid) == [45566, 12979])
    }

    /// Oldest first, because the only one worth acting on is the one that has been there
    /// long enough not to be a run somebody started a moment ago.
    @Test("puts the one that has been there longest first")
    func oldestFirst() {
        #expect(StrayCompiles.reading(Self.listing).first?.pid == 45566)
    }

    /// Which tree, because that is what says which run left it and where the copy it is
    /// still writing into lives.
    @Test("says which of this tool's trees each one is in")
    func namesTheTree() {
        let first = StrayCompiles.reading(Self.listing).first
        #expect(first?.tree == "swift-mutants-0753FAD1-1111-2222-3333-444455556666")
    }

    /// `ps` writes an elapsed time as `[[dd-]hh:]mm:ss`, and all three shapes turn up in
    /// one listing - a run started a moment ago, one an hour ago, one a day ago.
    @Test(
        "reads every shape of elapsed time ps prints",
        arguments: [
            ("00:06", 6), ("05:17", 317), ("1:02:03", 3723), ("01-23:39:24", 171_564),
        ])
    func readsElapsed(_ text: String, _ seconds: Int) {
        #expect(StrayCompiles.seconds(of: text) == seconds)
    }

    /// A machine with none of them says nothing, which is almost every machine.
    @Test("finds nothing on a machine with nothing running")
    func quietMachine() {
        let quiet = "  PID     ELAPSED COMMAND\n    1 00:01 /sbin/launchd"
        #expect(StrayCompiles.reading(quiet).isEmpty)
    }

    /// Nothing at all is not a crash. `ps` is a program that might not be there, or might
    /// say something this cannot read, and a doctor that fell over telling somebody about
    /// their machine would be worse than one that says nothing about this.
    @Test("reads nothing out of nothing")
    func nothingAtAll() {
        #expect(StrayCompiles.reading("").isEmpty)
        #expect(StrayCompiles.reading("garbage without any columns at all").isEmpty)
    }
}
