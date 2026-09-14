// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsCache

/// Which files a mutant's answer rests on.
///
/// The probe already knows. It records which guards each test evaluated, and every guard
/// is in a file, so the files a test runs are observed rather than guessed - which is what
/// makes a cache worth having at all: change one corner of a package and only the mutants
/// whose tests go near it have to be measured again.
@Suite("Dependencies")
struct DependenciesTests {

    static func path(_ name: String) -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/\(name).swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    /// Three files. `A` holds mutants 1 and 2, `B` holds 3, `C` holds none at all - it is
    /// a test file, or a file this tool found nothing to mutate in.
    static let one = Self.path("A")
    static let two = Self.path("B")
    static let bare = Self.path("C")

    static let files: [UInt32: WorkspaceRelativePath] = [1: one, 2: one, 3: two]
    static let digests: [WorkspaceRelativePath: Digest] = [
        one: Digest.of("A"), two: Digest.of("B"), bare: Digest.of("C"),
    ]

    static func map(
        reach: [String: Set<UInt32>],
        covering: [UInt32: [String]],
        digests: [WorkspaceRelativePath: Digest] = Self.digests
    ) -> [UInt32: [Digest]] {
        Dependencies.map(
            reach: reach, covering: covering, files: Self.files, digests: digests)
    }

    /// A mutant depends on the files the tests that reach it were seen to execute.
    @Test("rests on the files its own tests run")
    func restsOnWhatItsTestsRun() {
        let found = Self.map(reach: ["t": [1]], covering: [1: ["t"]])
        // `A`, because the test ran a guard there; and `C`, which nothing can observe.
        #expect(
            found[1]?.sorted { $0.hexadecimal < $1.hexadecimal }
                == [Digest.of("A"), Digest.of("C")].sorted { $0.hexadecimal < $1.hexadecimal })
    }

    /// Two tests reach it, and it rests on everything either of them runs.
    @Test("takes every one of its tests together")
    func takesEveryTest() {
        let found = Self.map(reach: ["t": [1], "u": [3]], covering: [1: ["t", "u"]])
        #expect(Set(found[1] ?? []) == Set([Digest.of("A"), Digest.of("B"), Digest.of("C")]))
    }

    /// The other direction, and the reason a cache earns its keep: a file no test of this
    /// mutant runs cannot change what those tests conclude, so changing it must not throw
    /// this answer away.
    @Test("does not rest on a file its tests never run")
    func notOnWhatTheyDoNotRun() {
        let found = Self.map(reach: ["t": [1], "u": [3]], covering: [1: ["t"]])
        #expect(!(found[1] ?? []).contains(Digest.of("B")))
    }

    /// A file with no mutants in it has no guards, so nothing can be observed about it and
    /// it has to be a dependency of everything. Test files are all of this kind, which is
    /// the case that matters: what a test concludes rests on the test.
    @Test("rests on every file nothing can be observed in")
    func restsOnTheUnobserved() {
        let found = Self.map(reach: ["t": [1]], covering: [1: ["t"]])
        #expect((found[1] ?? []).contains(Digest.of("C")))
    }

    /// A mutant nothing reaches still has an answer worth keeping - `uncovered` - and it
    /// rests on the files nothing can be observed in, because one of them appearing to run
    /// it would change that answer.
    @Test("holds a mutant no test reaches")
    func nothingReachesIt() {
        let found = Self.map(reach: ["t": [1]], covering: [:])
        #expect(found[3] == [Digest.of("C")])
    }

    /// A file whose digest is unknown makes the mutants that rest on it uncacheable, rather
    /// than cached against a dependency set that quietly omits it. Being slow is recoverable
    /// and being wrong is not.
    @Test("refuses to answer for a file it has no digest for")
    func refusesTheUnknown() {
        let found = Self.map(
            reach: ["t": [1, 3]], covering: [1: ["t"]], digests: [Self.one: Digest.of("A")])
        #expect(found[1] == nil)
    }

    /// And the same when a file nothing can be observed in has no digest: the remainder is
    /// part of every key, so an incomplete remainder makes every key wrong.
    @Test("refuses everything when it cannot see the whole package")
    func refusesAnIncompleteRemainder() {
        let found = Dependencies.map(
            reach: ["t": [1]],
            covering: [1: ["t"]],
            files: [1: Self.one, 2: Self.one, 3: Self.two, 9: Self.path("Missing")],
            digests: Self.digests
        )
        #expect(found.isEmpty)
    }
}
