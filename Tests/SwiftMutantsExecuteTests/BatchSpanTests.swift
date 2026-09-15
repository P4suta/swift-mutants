// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsInstrument
import Testing

@testable import SwiftMutantsExecute

/// Which bundles a batch spans, which is what it costs.
///
/// A batch used to cost one process, because a package used to build one test bundle. It
/// builds one per test target now, so a batch spanning three of them is three processes -
/// and a batch holding one mutant from each of two targets saves nothing at all while
/// looking exactly like a saving.
@Suite("Batches and the bundles they span")
struct BatchSpanTests {

    static func mutants() throws -> [InstrumentedMutant] { try SchedulerTests.mutants() }

    /// A batch used to cost one process. It now costs one per bundle it spans, because a
    /// package builds one test bundle per test target - so a batch of two mutants in two
    /// different targets costs two processes and saves nothing at all.
    ///
    /// Reported from a package with twenty-five bundles holding 1346 tests, several of
    /// them under fifteen: batching across the small ones cost almost as many processes as
    /// running the mutants alone would have.
    @Test("prefers mutants that live in the same bundle")
    func groupsWithinABundle() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(
            byMutant: [
                // Two in Core, one in App. A greedy that took the first disjoint group
                // would put Core and App together and leave the second Core mutant alone -
                // two batches spanning three bundles between them.
                mutants[0].index: ["CoreTests.S/a()"],
                mutants[1].index: ["AppTests.S/b()"],
                mutants[2].index: ["CoreTests.S/c()"],
            ],
        )
        let batches = Batch.group(Array(mutants.prefix(3)), using: coverage)
        let spans = batches.map { batch in
            Set(batch.tests.compactMap { $0.split(separator: ".").first.map(String.init) })
        }
        #expect(spans.allSatisfy { $0.count == 1 }, "\(spans)")
        // The two Core mutants share a process; App has its own.
        #expect(batches.count == 2)
        #expect(Set(batches.map(\.mutants.count)) == [2, 1])
    }

    /// A mutant whose tests span two bundles is not the same scheduling problem as one
    /// whose tests span one, and it does not join their batch: its batch would cost two
    /// processes where theirs costs one, and every member of theirs would be paying for it.
    @Test("keeps a mutant that spans two bundles out of a batch that spans one")
    func spansAreNotMixed() throws {
        let mutants = try Self.mutants()
        let coverage = Coverage(
            byMutant: [
                mutants[0].index: ["CoreTests.S/a()"],
                // Shares a test with the first, so it cannot join that group; and it is
                // the only other Core mutant, so there is no same-bundle group to take it.
                mutants[1].index: ["CoreTests.S/a()", "AppTests.S/b()"],
            ],
        )
        let batches = Batch.group(Array(mutants.prefix(2)), using: coverage)
        #expect(batches.count == 2)
    }
}
