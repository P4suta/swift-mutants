// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import Testing

@testable import SwiftMutantsExecute

/// What grouping costs, asserted rather than timed.
///
/// A grouping that quietly went quadratic would still produce exactly the right batches, so
/// no test about *what* it produces can catch it. The number of candidate groups the scan
/// looks through is what changes, and it is a deterministic function of the input - which
/// makes it something to assert on, where a stopwatch would only be a fact about this
/// machine on this afternoon.
///
/// The input that matters is not exotic. A package with one broad test that touches most of
/// the code has a coverage set for every mutant containing that test, so every pair of
/// mutants conflicts, no two can share a process, and every entry is compared against every
/// group opened so far. That package - thin tests, wide reach - is the one mutation testing
/// is most worth running on, so the worst case for grouping and the best case for the tool
/// are the same package.
@Suite("What grouping costs")
struct BatchComplexityTests {

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Wide.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    /// Mutants from real discovery and real instrumentation, because a hand-made one would
    /// be a fact about this test rather than about a catalogue.
    static func many(_ wanted: Int) throws -> [InstrumentedMutant] {
        var lines = ["func f(_ x: Int, _ y: Int) -> Bool {"]
        for line in 0..<wanted { lines.append("    let v\(line) = x < y") }
        lines.append("    return v0")
        lines.append("}")
        let source = lines.joined(separator: "\n")
        let discovery = Discover.candidates(in: source, at: Self.path())
        let mutants = try Instrument.file(source, discovery: discovery).mutants
            .sorted { $0.index < $1.index }
        return Array(mutants.prefix(wanted))
    }

    /// One test covering everything: nothing can be batched, which is the right answer, and
    /// arriving at it must not cost a comparison against every group opened so far.
    @Test("stays linear when one test covers the whole package")
    func oneTestCoversEverything() throws {
        let mutants = try Self.many(400)
        #expect(mutants.count == 400)

        let everything = "Pkg.WideTests/everything()"
        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.map { ($0.index, [everything]) }))

        let grouped = Batch.grouping(mutants, using: coverage)

        // Every mutant in a process of its own, because a test that reaches two of them
        // could not say which it was about. That part is unchanged and must stay so.
        #expect(grouped.batches.count == mutants.count)
        #expect(grouped.batches.allSatisfy { $0.mutants.count == 1 })

        #expect(
            grouped.examined <= mutants.count * Batch.window,
            """
            looked through \(grouped.examined) candidate groups for \(mutants.count) \
            mutants, which is more than \(Batch.window) each: the scan is growing with the \
            catalogue rather than with a bound
            """
        )
    }

    /// The good case has to stay good. Mutants that share nothing are what batching is for,
    /// and a bound on the scan must not stop them finding each other.
    @Test("still fills its batches when the mutants have nothing in common")
    func stillBatchesTheEasyCase() throws {
        let mutants = try Self.many(80)
        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.enumerated().map { position, mutant in
                    (mutant.index, ["Pkg.WideTests/only\(position)()"])
                }))

        let grouped = Batch.grouping(mutants, using: coverage)
        #expect(grouped.batches.count == 10, "\(grouped.batches.map(\.mutants.count))")
        #expect(grouped.batches.allSatisfy { $0.mutants.count == 8 })
    }

    /// The rule that makes a batch sound, restated over an input large enough that a bound
    /// on the scan could break it: no test reaches two mutants of one process.
    @Test("never puts two mutants a test shares into one process")
    func neverSharesATest() throws {
        let mutants = try Self.many(200)
        // Every fifth mutant shares a test with the one five before it, so conflicts are
        // spread through the catalogue rather than confined to neighbours.
        let coverage = Coverage(
            byMutant: Dictionary(
                uniqueKeysWithValues: mutants.enumerated().map { position, mutant in
                    (mutant.index, ["Pkg.WideTests/group\(position % 5)()"])
                }))

        for batch in Batch.grouping(mutants, using: coverage).batches {
            var seen: Set<String> = []
            for mutant in batch.mutants {
                let tests = Set(coverage.tests(reaching: mutant.index) ?? [])
                #expect(seen.isDisjoint(with: tests), "a test reaches two mutants of a batch")
                seen.formUnion(tests)
            }
        }
    }
}
