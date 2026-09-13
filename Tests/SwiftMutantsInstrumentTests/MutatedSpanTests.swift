// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsInstrument

/// Where each mutant's own copy of the expression ended up.
///
/// This is what makes one typecheck enough. `swiftc` reports every error in a file rather
/// than stopping at the first, and points `line:col` at the operator inside the branch
/// that broke - so if the instrumenter says where it put each mutated copy, a diagnostic
/// lands on exactly one mutant and the whole file's rejections are known from a single
/// compile. Without it the only way to find out which mutant broke the build is to bisect,
/// which costs a compile per halving instead of one for the lot.
///
/// The spans are disjoint by construction: a guard's mutated side carries a pristine
/// flattened copy of the expression with one edit in it and no nested guards, because only
/// one mutant is ever awake and a guard nested in there could never fire. The nested guards
/// live on the original side instead.
@Suite("Mutated spans")
struct MutatedSpanTests {

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func instrument(_ source: String) throws -> InstrumentedFile {
        try Instrument.file(source, discovery: Discover.candidates(in: source, at: Self.path()))
    }

    /// Reads back what the instrumenter claims it wrote.
    static func text(_ span: SourceSpan, of file: InstrumentedFile) -> String {
        String(decoding: Array(file.source.utf8)[span.start..<span.end], as: UTF8.self)
    }

    @Test("points at the copy carrying the edit")
    func pointsAtTheMutatedCopy() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { return a < b }")
        let mutant = try #require(file.mutants.first)
        #expect(mutant.rule.name == "lt-to-le")
        #expect(Self.text(mutant.instrumentedSpan, of: file) == "a <= b")
    }

    @Test("points at each alternative when one expression has several")
    func severalAlternativesAtOneSite() throws {
        let file = try Self.instrument("func f(_ a: Bool, _ b: Bool) -> Bool { return a && b }")
        let texts = file.mutants.map { Self.text($0.instrumentedSpan, of: file) }.sorted()
        #expect(texts == ["a", "a || b", "b"])
    }

    /// The case the disjointness argument rests on: an outer site whose original side
    /// holds an inner site's guards, and whose own mutated sides hold neither.
    @Test("keeps nested sites out of each other's copies")
    func nestedSitesAreDisjoint() throws {
        let file = try Self.instrument(
            "func f(_ a: Int, _ b: Int) -> Bool { return a < b && a > b }"
        )
        let spans = file.mutants.map(\.instrumentedSpan).sorted()
        for (earlier, later) in zip(spans, spans.dropFirst()) {
            #expect(!earlier.overlaps(later), "\(earlier) overlaps \(later)")
        }
        for mutant in file.mutants {
            let text = Self.text(mutant.instrumentedSpan, of: file)
            #expect(!text.contains("__sm_"), "a mutated copy carries a guard: \(text)")
        }

        // Read every one of them back. Disjointness alone would still hold if each span
        // were a byte to the left, and attribution would then hand a diagnostic about the
        // last byte of one mutant to the mutant beside it.
        #expect(
            file.mutants.map { Self.text($0.instrumentedSpan, of: file) }.sorted()
                == ["a < b", "a < b || a > b", "a <= b", "a > b", "a >= b"]
        )
    }

    /// Every span has to be inside the file it is a span of, or attribution reads bytes
    /// belonging to some other mutant - or trips over the end of the file.
    @Test(
        "stays inside the instrumented file",
        arguments: [
            "func f(_ a: Int, _ b: Int) -> Bool { return a < b }",
            """
            func f(_ a: Int, _ b: Int) -> Bool {
                return a < b
                    && a > b
            }
            """,
            "func f(_ a: Bool) -> Bool { a == true }",
        ])
    func staysInsideTheFile(source: String) throws {
        let file = try Self.instrument(source)
        let byteCount = file.source.utf8.count
        #expect(!file.mutants.isEmpty)
        for mutant in file.mutants {
            #expect(mutant.instrumentedSpan.start >= 0)
            #expect(mutant.instrumentedSpan.end <= byteCount)
            #expect(mutant.instrumentedSpan.start < mutant.instrumentedSpan.end)
        }
    }

    /// The edit itself must be in there. A span that merely overlapped the right region
    /// would still attribute most diagnostics correctly and would be wrong exactly where
    /// it matters.
    @Test("contains the replacement bytes")
    func containsTheReplacement() throws {
        let file = try Self.instrument(
            """
            func f(_ a: Int, _ b: Int) -> Bool {
                return a <= b
            }
            """
        )
        let mutant = try #require(file.mutants.first { $0.rule.name == "le-to-lt" })
        #expect(Self.text(mutant.instrumentedSpan, of: file).contains("a < b"))
    }
}
