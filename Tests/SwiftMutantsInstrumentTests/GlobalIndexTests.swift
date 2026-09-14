// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsInstrument

/// One environment variable, one mutant awake.
///
/// Every instrumented file reads the same `SWIFT_MUTANTS_ACTIVE`, so an index numbered from
/// zero in each file means one value wakes the same index in *all* of them. Measured on
/// this repository: fifty-nine files, so a run asking for mutant 3 woke up to fifty-nine
/// mutants at once and then reported what it learned as a fact about one of them.
///
/// That is Muter's four hundred false regressions in the other direction - not a mutant
/// missing from the tree, but a tree full of mutants nobody asked for - and it produces the
/// same kind of confident, wrong number.
@Suite("Global indices")
struct GlobalIndexTests {

    static func path(_ name: String) -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/\(name).swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func instrument(
        _ source: String, named name: String, startingAt base: UInt32
    )
        throws -> InstrumentedFile
    {
        try Instrument.file(
            source,
            discovery: Discover.candidates(in: source, at: Self.path(name)),
            startingAt: base
        )
    }

    @Test("numbers a file from where the last one stopped")
    func continuesFromTheBase() throws {
        let first = try Self.instrument(
            "func f(_ a: Int, _ b: Int) -> Bool { a < b && a > b }", named: "One", startingAt: 0)
        let second = try Self.instrument(
            "func g(_ a: Int, _ b: Int) -> Bool { a < b }",
            named: "Two",
            startingAt: first.nextIndex
        )

        #expect(first.mutants.map(\.index).sorted() == Array(0..<UInt32(first.mutants.count)))
        #expect(second.mutants.map(\.index) == [first.nextIndex])
    }

    /// The property the whole activation scheme rests on.
    @Test("gives no two mutants in a run the same index")
    func indicesAreUniqueAcrossFiles() throws {
        var next: UInt32 = 0
        var indices: [UInt32] = []
        for (position, source) in [
            "func a(_ x: Int, _ y: Int) -> Bool { x < y }",
            "func b(_ x: Int, _ y: Int) -> Bool { x > y && x != y }",
            "func c(_ x: Bool) -> Bool { x == true }",
        ].enumerated() {
            let file = try Self.instrument(source, named: "File\(position)", startingAt: next)
            indices += file.mutants.map(\.index)
            next = file.nextIndex
        }
        #expect(indices.count > 3)
        #expect(Set(indices).count == indices.count, "two mutants share an index: \(indices)")
    }

    /// A guard spells the global number, because that is what the environment carries.
    @Test("writes the global number into the guard")
    func guardsSpellTheGlobalNumber() throws {
        let file = try Self.instrument(
            "func f(_ a: Int, _ b: Int) -> Bool { a < b }", named: "One", startingAt: 41)
        let mutant = try #require(file.mutants.first)
        #expect(mutant.index == 41)
        #expect(file.source.contains("__sm_\(file.runtimeToken)(41 "))
    }

    /// Identity is content-addressed, so renumbering must not rename anything. Otherwise
    /// adding a file at the top of a package would invalidate every cached outcome below it.
    @Test("does not rename a mutant when the numbering moves")
    func identitiesDoNotMoveWithIndices() throws {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { a < b }"
        let low = try Self.instrument(source, named: "One", startingAt: 0)
        let high = try Self.instrument(source, named: "One", startingAt: 900)
        #expect(low.mutants.map(\.identity) == high.mutants.map(\.identity))
        #expect(low.mutants.map(\.index) != high.mutants.map(\.index))
    }

    /// A file with nothing in it moves the numbering along by nothing.
    @Test("leaves the numbering where it found it when there is nothing to do")
    func emptyFileDoesNotConsumeIndices() throws {
        let file = try Self.instrument("let greeting = \"hello\"", named: "One", startingAt: 7)
        #expect(file.mutants.isEmpty)
        #expect(file.nextIndex == 7)
    }
}
