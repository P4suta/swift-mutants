// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsInstrument

/// Two sites no splice order can satisfy, and what the refusal has to say about them.
///
/// Whichever of two overlapping sites were written first would destroy the bytes the other
/// was measured against, so a file holding a pair like that cannot be instrumented at all.
///
/// It is reachable from a project's own `[[mutation.custom]]` rows: an anchor that starts
/// or ends part-way through a node overlaps the site generated at the same place without
/// containing it. Reported from a package where one such row - its `find` carrying the
/// line's indentation - stopped a run of 3223 mutants, with a message that named the file
/// and not the pair. They found the two by grepping the catalogue for the filename, which
/// worked only because they already suspected their own rows.
///
/// The padding that caused that particular one is now refused when the row is read. This is
/// about what the refusal says when a pair gets here anyway, because the general shape -
/// any anchor that begins or ends mid-node - is still writable.
@Suite("Two sites that cannot both be spliced")
struct ConflictingSitesTests {

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func span(_ start: Int, _ end: Int) -> SourceSpan {
        guard let span = SourceSpan(start: start, end: end) else {
            fatalError("malformed fixture span")
        }
        return span
    }

    /// A row anchored across the end of a generated site.
    ///
    /// `[0] + a` is a concatenation, so there is a site over the whole of it. An anchor
    /// that begins inside it and ends past it is neither inside nor outside, which is
    /// exactly the shape the report described - their anchor carried the line's
    /// indentation, so it began *before* the expression instead of after, but neither
    /// contains the other either way.
    static let source = "func f(_ a: [Int]) -> [Int] { [0] + a }"

    static func discovery() -> FileDiscovery {
        Discover.candidates(
            in: Self.source,
            at: Self.path(),
            custom: [
                CustomMutant(
                    find: "+ a }",
                    replace: "+ a  }",
                    reason: "is the suffix load-bearing")
            ])
    }

    @Test("says which two places it could not put in an order")
    func namesBothSites() throws {
        let discovery = Self.discovery()
        let own = try #require(discovery.candidates.first { $0.rule.name == "custom" })
        let generated = try #require(discovery.candidates.first { $0.rule.name != "custom" })
        // The premise. Without a genuine overlap this asserts nothing about the message,
        // which is how a test of an error message passes while the message says nothing.
        #expect(own.guardSpan.overlaps(generated.guardSpan))
        #expect(!own.guardSpan.contains(generated.guardSpan))
        #expect(!generated.guardSpan.contains(own.guardSpan))

        var said = ""
        do {
            _ = try Instrument.file(Self.source, discovery: discovery)
            Issue.record("a pair that cannot be spliced was accepted")
        } catch {
            said = "\(error)"
        }
        // Both places, so a reader goes to two lines rather than to a file.
        #expect(said.contains("\(own.guardSpan.start)"), "\(said)")
        #expect(said.contains("\(own.guardSpan.end)"), "\(said)")
        #expect(said.contains("\(generated.guardSpan.start)"), "\(said)")
        #expect(said.contains("\(generated.guardSpan.end)"), "\(said)")
        #expect(said.contains("Sources/Subject.swift"), "\(said)")
    }

    /// Nesting is not conflict, and has to keep working: the expression one mutant rewrites
    /// very often sits inside the one another rewrites, and that is the ordinary case.
    @Test("is happy with a site inside another site")
    func nestingIsFine() throws {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { a < b && a > 0 }"
        let discovery = Discover.candidates(in: source, at: Self.path())
        #expect(throws: Never.self) { try Instrument.file(source, discovery: discovery) }
        #expect(!discovery.candidates.isEmpty)
    }
}
