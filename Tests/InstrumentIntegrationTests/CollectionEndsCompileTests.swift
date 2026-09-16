// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsInstrument

/// The compiler's opinion of one end of a collection named as the other.
///
/// The pairs return the same type as each other, which is what lets a ternary hold both -
/// but only where both *exist*. `Set` has `first` and no `last`; `lastIndex` needs a
/// bidirectional collection and `removeLast` a replaceable one. Discovery cannot tell,
/// having no types, so the question is what the compiler makes of each shape and how much
/// of it is refused.
///
/// The refusals are the point of measuring rather than a reason not to: a rejection is a
/// first-class outcome here, reported with the compiler's own words. But a rule that is
/// refused more often than not is a rule that spends a build to say nothing, and only a
/// compiler can say which this is.
@Suite("Compiling one end of a collection as the other", .tags(.integration))
struct CollectionEndsCompileTests {

    static func instrument(_ source: String) throws -> InstrumentedFile {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        return try Instrument.file(
            source,
            discovery: Discover.candidates(in: source, at: path, selecting: mutation))
    }

    /// Every pair, on a receiver that has both halves.
    static let bidirectional = """
        func head(_ xs: [Int]) -> Int? { xs.first }
        func tail(_ xs: [Int]) -> Int? { xs.last }
        func smallest(_ xs: [Int]) -> Int? { xs.min() }
        func largest(_ xs: [Int]) -> Int? { xs.max() }
        func front(_ xs: [Int]) -> ArraySlice<Int> { xs.prefix(3) }
        func back(_ xs: [Int]) -> ArraySlice<Int> { xs.suffix(3) }
        func rest(_ xs: [Int]) -> ArraySlice<Int> { xs.dropFirst() }
        func most(_ xs: [Int]) -> ArraySlice<Int> { xs.dropLast() }
        func starts(_ s: String, _ p: String) -> Bool { s.hasPrefix(p) }
        func ends(_ s: String, _ p: String) -> Bool { s.hasSuffix(p) }
        func where_(_ xs: [Int], _ n: Int) -> Int? { xs.firstIndex(of: n) }
        func lastWhere(_ xs: [Int], _ n: Int) -> Int? { xs.lastIndex(of: n) }
        func takeFront(_ xs: inout [Int]) -> Int { xs.removeFirst() }
        func takeBack(_ xs: inout [Int]) -> Int { xs.removeLast() }
        """

    @Test("compiles every pair on a collection that has both ends")
    func compilesBothEnds() throws {
        let instrumented = try Self.instrument(Self.bidirectional)
        let said = try InlinableTests.compile(["Subject.swift": instrumented.source])
        #expect(said.exitCode == 0, "\(said.text)")
    }

    /// The premise: without the swaps actually landing, the above compiles an ordinary file.
    @Test("swaps every pair in the fixture")
    func theSwapsAreThere() throws {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        let found = Discover.candidates(in: Self.bidirectional, at: path, selecting: mutation)
            .candidates.filter { $0.rule.name.hasPrefix("swap-") }
        #expect(found.count == 14, "\(found.map(\.rule.name))")
    }

    /// And the shape the rule cannot know about: a receiver with only one of the two. This
    /// is *expected* to be refused, and the test exists to record how - so that a change
    /// which starts refusing the ordinary cases too is visible as a change rather than as
    /// a number nobody was watching.
    @Test("is refused where the receiver has only one end, and says so")
    func oneEndedReceiver() throws {
        let instrumented = try Self.instrument(
            "func any(_ xs: Set<Int>) -> Int? { xs.first }")
        let said = try InlinableTests.compile(["Subject.swift": instrumented.source])
        #expect(said.exitCode != 0, "a Set has no `last`, so this cannot compile")
        #expect(said.text.contains("last"), "\(said.text)")
    }
}
