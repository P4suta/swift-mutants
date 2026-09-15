// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// Finding the place a project's own mutant is about.
///
/// Anchored by text rather than by position, because a position moves whenever anything
/// above it does and a project would be rewriting its catalogue after every edit.
///
/// The anchor has to appear exactly once, and the two ways it can fail want completely
/// different fixes: appearing twice is a too-short anchor, appearing never is code that
/// moved. So the count is in the message either way - which is what somebody who had done
/// this by hand for 290 rows reported was the thing that made it a two-minute fix.
///
/// And the row is named by what it says rather than by where it is. "hold frames until the
/// memory runs out" tells somebody instantly what moved; a span or a digest tells them
/// nothing.
@Suite("Finding a project's own mutant")
struct CustomAnchorTests {

    static let source = """
        func rank(_ entries: [Int]) -> [Int] {
            let wrong = entries.filter { $0 < 0 }
            return wrong.sorted()
        }
        """

    static func row(
        find: String,
        replace: String = "wrong",
        reason: String = "is the sort load-bearing",
        line: Int? = nil
    ) -> CustomMutant {
        CustomMutant(find: find, replace: replace, reason: reason, line: line)
    }

    static func discovery(_ rows: [CustomMutant], in source: String = Self.source) -> FileDiscovery
    {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return Discover.candidates(in: source, at: path, custom: rows)
    }

    @Test("finds an anchor that appears once")
    func findsOne() throws {
        let found = Self.discovery([Self.row(find: "wrong.sorted()")])
        let custom = found.candidates.filter { $0.rule.name == "custom" }
        #expect(custom.count == 1)
        #expect(custom.first?.original == "wrong.sorted()")
        #expect(custom.first?.replacement == "wrong")
    }

    /// The span is the anchor's own bytes, which is what makes the mutant's identity move
    /// with the code rather than with the file.
    @Test("spans exactly the bytes of the anchor")
    func spansTheAnchor() throws {
        let found = Self.discovery([Self.row(find: "wrong.sorted()")])
        let mutant = try #require(found.candidates.first { $0.rule.name == "custom" })
        let bytes = Array(Self.source.utf8)
        #expect(
            String(decoding: bytes[mutant.span.start..<mutant.span.end], as: UTF8.self)
                == "wrong.sorted()")
    }

    /// Code moved and the row stopped testing anything. Silence here is the failure this
    /// whole tool is about: somebody carries on believing they have coverage they do not,
    /// and believes it specifically about the code they just changed.
    @Test("says so when an anchor is not there")
    func missingAnchor() throws {
        let found = Self.discovery([Self.row(find: "entries.deduplicated()")])
        #expect(!found.candidates.contains { $0.rule.name == "custom" })
        let skip = try #require(found.skips.first { $0.reason == .customAnchorNotFound })
        #expect(skip.candidatesHidden == 1)
    }

    /// A too-short anchor is a different mistake from a moved one, so the count is said.
    @Test("says so when an anchor is there more than once")
    func ambiguousAnchor() throws {
        let found = Self.discovery([Self.row(find: "wrong", replace: "entries")])
        #expect(!found.candidates.contains { $0.rule.name == "custom" })
        #expect(found.skips.contains { $0.reason == .customAnchorNotUnique })
    }

    /// The escape hatch for when a longer anchor is genuinely not available.
    @Test("takes a line to tell two the same apart")
    func aLineDisambiguates() throws {
        let found = Self.discovery([Self.row(find: "wrong", replace: "entries", line: 3)])
        let custom = found.candidates.filter { $0.rule.name == "custom" }
        #expect(custom.count == 1)
        // The one on line 3, not the one on line 2.
        let bytes = Array(Self.source.utf8)
        let before = String(decoding: bytes[0..<(custom.first?.span.start ?? 0)], as: UTF8.self)
        #expect(before.filter { $0 == "\n" }.count == 2)
    }

    /// A line that names no occurrence is as stale as an anchor that names none.
    @Test("says so when the line has no such anchor")
    func wrongLine() throws {
        let found = Self.discovery([Self.row(find: "wrong.sorted()", line: 1)])
        #expect(!found.candidates.contains { $0.rule.name == "custom" })
        #expect(found.skips.contains { $0.reason == .customAnchorNotFound })
    }

    /// Rows for other files are not this file's business.
    @Test("finds nothing when there are no rows")
    func noRows() {
        #expect(Self.discovery([]).candidates.allSatisfy { $0.rule.name != "custom" })
    }

    /// Two rows may name one place when they replace it differently - that is two
    /// questions about one expression, and both are worth asking.
    @Test("finds one anchor twice when two rows ask different things")
    func twoQuestionsOnePlace() {
        let found = Self.discovery([
            Self.row(find: "wrong.sorted()", replace: "wrong"),
            Self.row(find: "wrong.sorted()", replace: "[]"),
        ])
        #expect(found.candidates.filter { $0.rule.name == "custom" }.count == 2)
    }

    /// Bytes, not characters. A span is bytes everywhere else in this tool, so a mutant
    /// anchored by character offsets would point somewhere else the moment somebody put an
    /// accent above it - and the mutant would then edit the middle of a different
    /// expression, silently, in a file that still compiles.
    @Test("counts an anchor in bytes, under text that is not ASCII")
    func bytesNotCharacters() throws {
        let source = """
            func f() -> String {
                let gruß = "schön"
                return gruß.uppercased()
            }
            """
        let found = Self.discovery(
            [Self.row(find: "gruß.uppercased()", replace: "gruß")], in: source)
        let mutant = try #require(found.candidates.first { $0.rule.name == "custom" })
        let bytes = Array(source.utf8)
        #expect(
            String(decoding: bytes[mutant.span.start..<mutant.span.end], as: UTF8.self)
                == "gruß.uppercased()")
    }

    /// An empty anchor is in a file at every position and at none of them. The
    /// configuration refuses one, and so does this: a public type is constructible by
    /// anybody, and a guard that only holds because of who calls it is a guard.
    @Test("finds nothing for an anchor that is nothing")
    func emptyAnchor() {
        let found = Self.discovery([Self.row(find: "", replace: "x")])
        #expect(found.candidates.allSatisfy { $0.rule.name != "custom" })
        #expect(found.skips.contains { $0.reason == .customAnchorNotFound })
    }

    /// A project's own mutants sit beside the generated ones rather than instead of them.
    @Test("leaves the generated ones alone")
    func alongsideTheGenerated() {
        let found = Self.discovery([Self.row(find: "wrong.sorted()")])
        #expect(found.candidates.contains { $0.rule.name == "lt-to-le" })
        #expect(found.candidates.contains { $0.rule.name == "custom" })
    }

    /// In span order with everything else, so a report does not put them in a clump at the
    /// end and a reader can find them where the code is.
    @Test("sits in the file's order")
    func inOrder() {
        let found = Self.discovery([Self.row(find: "wrong.sorted()")])
        #expect(found.candidates.map(\.span) == found.candidates.map(\.span).sorted())
    }
}
