// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsInstrument

/// Instrumented expressions preserve source locations and original comments.
@Suite("An expression with a comment in it")
struct CommentedExpressionTests {

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func discovered(_ source: String) -> FileDiscovery {
        Discover.candidates(in: source, at: Self.path())
    }

    /// Detects fixtures where instrumentation must remove a comment inside a mutation site.
    static func holdsACommentInASite(_ discovery: FileDiscovery) -> Bool {
        discovery.lineComments.contains { comment in
            discovery.candidates.contains {
                $0.guardSpan.start <= comment.start && comment.end <= $0.guardSpan.end
            }
        }
    }

    static func instrumented(_ source: String) throws -> InstrumentedFile {
        let discovery = Self.discovered(source)
        #expect(Self.holdsACommentInASite(discovery), "no site in this fixture holds a comment")
        return try Instrument.file(source, discovery: discovery)
    }

    static let commentedArgument = """
        func all(_ existing: [Row], _ name: String) -> [Row] {
            existing
                + [
                    Row(
                        name: name,
                        // Left unset on purpose: whatever reads this decides,
                        // and nothing upstream is allowed to.
                        position: 1
                    )
                ]
        }
        """

    @Test("instruments an expression whose argument carries a comment")
    func instrumentsACommentedArgument() throws {
        let file = try Self.instrumented(Self.commentedArgument)
        #expect(!file.mutants.isEmpty, "nothing was instrumented")
    }

    /// The original side preserves the source comment byte for byte.
    @Test("leaves the comment in the copy that is not mutated")
    func keepsTheCommentOnTheOriginalSide() throws {
        let file = try Self.instrumented(Self.commentedArgument)
        #expect(file.source.contains("// Left unset on purpose: whatever reads this decides,"))
    }

    /// Appended instrumentation must preserve the original source line numbers.
    @Test("keeps the file exactly as many lines long as it was")
    func preservesTheLineCount() throws {
        let file = try Self.instrumented(Self.commentedArgument)
        let before = Self.commentedArgument.split(separator: "\n", omittingEmptySubsequences: false)
        // The runtime is appended after the last line, so the file's own lines are the ones before it.
        let after = file.source.replacingOccurrences(of: file.runtime, with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
        #expect(after.count == before.count, "\(before.count) lines became \(after.count)")
    }

    /// A line comment in the flattened mutation would hide the rest of its guard.
    @Test("puts no line comment in a copy that has to be one line")
    func noCommentSurvivesIntoAMutatedCopy() throws {
        let file = try Self.instrumented(Self.commentedArgument)
        let bytes = Array(file.source.utf8)
        for mutant in file.mutants {
            let copy = String(
                decoding: bytes[mutant.span.start..<mutant.span.end], as: UTF8.self)
            #expect(!copy.contains("//"), "\(copy)")
        }
    }

    @Test("is not confused by two slashes inside a string")
    func slashesInAStringAreNotAComment() throws {
        let source = """
            func url(_ host: String, _ port: Int) -> String {
                "https://" + host + ":" + (port > 0 ? "\\(port)" : "443")
            }
            """
        let discovery = Self.discovered(source)
        #expect(discovery.lineComments.isEmpty, "a string's slashes were read as a comment")
        let file = try Instrument.file(source, discovery: discovery)
        #expect(!file.mutants.isEmpty, "nothing was instrumented")
        #expect(file.source.contains("https://"))
    }

    /// A multiline string's newlines prevent flattening its enclosing expression.
    @Test("passes over an expression holding a multi-line string, and says so")
    func multilineStringIsASkipRatherThanAStop() throws {
        // The guard wraps the concatenation, including the literal's significant newlines.
        let source = #"""
            func banner(_ head: String) -> String {
                head + """
                    many
                    lines
                    """
            }
            """#
        let discovery = Discover.candidates(in: source, at: Self.path())
        #expect(discovery.skips.contains { $0.reason == .multilineString })
        // And it still instruments, rather than refusing the file.
        #expect(throws: Never.self) { try Instrument.file(source, discovery: discovery) }
    }
}
