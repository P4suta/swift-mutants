// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsTCE

/// Reading a set of fingerprints.
///
/// Once every survivor has been compiled and hashed, two things fall out at once. A mutant
/// whose program is the original's cannot be caught by anything and should never have been
/// reported; and two mutants whose programs are each other's are one finding written twice,
/// which is somebody reading the same line of code four times.
///
/// Both are answers about the code rather than about the tests, which is why they are worth
/// having: no amount of test-writing changes either of them.
@Suite("Reading fingerprints")
struct EquivalenceTests {

    static func digest(_ name: String) -> Digest { Digest.of(name) }

    static func found(
        _ mutants: [(UInt32, String)], original: String = "original"
    ) -> Equivalence {
        Equivalence(
            of: Dictionary(uniqueKeysWithValues: mutants.map { ($0.0, Self.digest($0.1)) }),
            matching: Self.digest(original)
        )
    }

    @Test("finds the mutant that compiled to the original")
    func findsEquivalent() {
        let found = Self.found([(1, "original"), (2, "different")])
        #expect(found.equivalent == [1])
    }

    @Test("says nothing is equivalent when nothing is")
    func findsNone() {
        #expect(Self.found([(1, "a"), (2, "b")]).equivalent.isEmpty)
    }

    /// Two mutants that compile to each other are one finding. The first in catalogue order
    /// keeps its place and the rest point at it, so a report can say "the same as" rather
    /// than repeating the line.
    @Test("groups mutants that compiled to each other")
    func findsDuplicates() {
        let found = Self.found([(1, "a"), (2, "a"), (3, "b"), (4, "a")])
        #expect(found.duplicates[2] == 1)
        #expect(found.duplicates[4] == 1)
        #expect(found.duplicates[3] == nil)
        #expect(found.duplicates[1] == nil, "the first of a group is not a duplicate of itself")
    }

    /// A mutant equivalent to the original is not also reported as a duplicate of another
    /// equivalent one: it is already the strongest thing that can be said about it.
    @Test("does not call an equivalent mutant a duplicate as well")
    func equivalenceWins() {
        let found = Self.found([(1, "original"), (2, "original")])
        #expect(found.equivalent.sorted() == [1, 2])
        #expect(found.duplicates.isEmpty)
    }

    @Test("holds a set with nothing in it")
    func empty() {
        let found = Self.found([])
        #expect(found.equivalent.isEmpty)
        #expect(found.duplicates.isEmpty)
    }

    /// The lowest index is the one that keeps its place, so two runs of the same package
    /// point the same way.
    @Test("points a group at the same member every time")
    func stableRepresentative() {
        #expect(Self.found([(9, "a"), (3, "a"), (7, "a")]).duplicates == [7: 3, 9: 3])
    }
}
