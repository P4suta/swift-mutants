// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsExecute

/// Measuring a package's whole catalogue, rather than one file at a time.
///
/// A run used to hand the scheduler one file's mutants, wait for them, and then hand it the
/// next file's. Two things follow from that and both are pure loss.
///
/// A batch is several mutants in one process, sound because no test reaches two of them -
/// which is a fact about their covering tests and has nothing to do with which file they
/// are in. Grouping inside one file at a time throws away every pairing across files, and
/// on a package whose files each have a handful of mutants covered by the same few tests,
/// that is most of the pairings there are.
///
/// And the pool drains at every file boundary. With eighteen workers and a file holding
/// five mutants, thirteen of them wait for the last one to finish before the next file
/// starts. A package of fifty files is fifty of those stalls.
///
/// So a mutant carries the file it came from - the instrumenter knows it, and knew it all
/// along - and the whole catalogue goes in at once.
@Suite("The whole catalogue at once")
struct WholeCatalogueTests {

    static func path(_ name: String) -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/\(name).swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    /// Two files' worth, numbered through as a run numbers them: every instrumented file
    /// reads the same environment variable, so a second file numbered from zero would wake
    /// mutants in both.
    static func twoFiles() throws -> (first: [InstrumentedMutant], second: [InstrumentedMutant]) {
        let one = "func f(_ a: Int, _ b: Int) -> Bool { a < b }"
        let two = "func g(_ c: Int, _ d: Int) -> Bool { c > d }"
        let first = try Instrument.file(
            one, discovery: Discover.candidates(in: one, at: Self.path("First")))
        let second = try Instrument.file(
            two,
            discovery: Discover.candidates(in: two, at: Self.path("Second")),
            startingAt: first.nextIndex)
        return (first.mutants, second.mutants)
    }

    /// The fact that makes the rest possible: a mutant knows which file it came from, so
    /// nothing outside has to be told alongside it.
    @Test("carries the file it came from")
    func knowsItsFile() throws {
        let (first, second) = try Self.twoFiles()
        #expect(first.allSatisfy { $0.path == Self.path("First") })
        #expect(second.allSatisfy { $0.path == Self.path("Second") })
    }

    /// One process for two mutants in different files, because a test that reaches one
    /// reaches neither of the other's - which is the only thing a batch requires.
    @Test("puts mutants from different files in one process when no test reaches two")
    func batchesAcrossFiles() throws {
        let (first, second) = try Self.twoFiles()
        let mutants = [first[0], second[0]]
        let coverage = Coverage(
            byMutant: [
                first[0].index: ["Pkg.FirstTests/one()"],
                second[0].index: ["Pkg.SecondTests/two()"],
            ])

        let batches = Batch.group(mutants, using: coverage)
        #expect(batches.count == 1, "\(batches.map(\.mutants.count))")
        #expect(Set(batches[0].mutants.map(\.path)) == [Self.path("First"), Self.path("Second")])
    }

    /// And each of them is answered about its own file. A batch that reported both under
    /// one path would put a survivor's line number in a file that has no such line.
    @Test("answers each mutant about the file it came from")
    func answersAboutItsOwnFile() async throws {
        let (first, second) = try Self.twoFiles()
        let mutants = [first[0], second[0]]
        let watch = TokenWatch(releasingAfter: mutants.count)
        let scheduler = Scheduler(
            host: { worker, _ in Recording(token: worker, watch: watch) },
            jobs: 2
        )

        let results = await scheduler.run(mutants)
        #expect(results.count == 2)
        #expect(results.first { $0.identity == first[0].identity }?.path == Self.path("First"))
        #expect(results.first { $0.identity == second[0].identity }?.path == Self.path("Second"))
    }
}
