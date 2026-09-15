// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsInstrument

/// An expression with a comment inside it.
///
/// The mutated copy of a site is put on one line, because the original copy beside it keeps
/// every newline the file had and a copy that kept its own would add them - and every line
/// number in an instrumented file has to equal the original's, or the coverage a run reads
/// back is about different lines than the ones it measured.
///
/// A line comment runs to the end of its line, so joining the lines would put everything
/// after it inside the comment. This used to be a refusal, and the refusal stopped the
/// whole run: one site, one file, after the entire instrument-and-validate pass was already
/// paid for. Reported from a package with **87 of them across 32 files**, each one a
/// comment explaining an argument at the argument:
///
/// ```swift
/// Annotation(
///     id: Self.nextID(in: scene),
///     label: label,
///     // Without a placement, which is the point: the solver decides where it goes.
///     placement: nil
/// )
/// ```
///
/// That is not an unusual codebase, it is a commented one, and a tool a project has to
/// move 87 comments for is a tool that measures less than the project's own harness.
///
/// The answer is that a comment has no meaning to a compiler, so the mutated copy simply
/// does without it. The original copy beside it keeps every byte, comment included, so
/// nothing a person reads loses anything.
///
/// It could not be done on bytes because `//` inside a string literal is not a comment, and
/// the refusal it replaced could not tell the two apart. Discovery has the tree, so it says
/// where the comments are and the splice takes exactly those bytes out.
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

    /// Refuses to let any of this pass because nothing was tested.
    ///
    /// The first version of these tests used an argument list with a comment in it - which
    /// is what the report described - and every one of them passed however the flattening
    /// was written. The site a guard wraps for `count > 0` is `count > 0`, which does not
    /// reach the comment three lines above it, so no copy ever held one and nothing was
    /// being asserted. Perturbing the removal left them green, which is what a tautology
    /// looks like from inside.
    ///
    /// The shape that does reach it is a concatenation, because the site is then the whole
    /// multi-line expression - which is also the shape in the report, one example further
    /// down: `scene.annotations + [Annotation(… // … , placement: nil)]`.
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
        func all(_ existing: [Thing], _ label: String) -> [Thing] {
            existing
                + [
                    Thing(
                        label: label,
                        // Without a placement, which is the point: the solver
                        // decides where it goes, and nobody drags it there.
                        count: 1
                    )
                ]
        }
        """

    @Test("instruments an expression whose argument carries a comment")
    func instrumentsACommentedArgument() throws {
        let file = try Self.instrumented(Self.commentedArgument)
        #expect(!file.mutants.isEmpty, "nothing was instrumented")
    }

    /// The original side keeps every byte it had. A person reading the instrumented tree,
    /// or running `swift-mutants apply`, sees their own code with their own comment.
    @Test("leaves the comment in the copy that is not mutated")
    func keepsTheCommentOnTheOriginalSide() throws {
        let file = try Self.instrumented(Self.commentedArgument)
        #expect(file.source.contains("// Without a placement, which is the point: the solver"))
    }

    /// The whole reason for flattening. A file that gained lines would make every line
    /// number after the site wrong, and the coverage a run reads back is by line.
    @Test("keeps the file exactly as many lines long as it was")
    func preservesTheLineCount() throws {
        let file = try Self.instrumented(Self.commentedArgument)
        let before = Self.commentedArgument.split(separator: "\n", omittingEmptySubsequences: false)
        // The runtime is appended after the last line, so the file's own lines are the
        // ones before it.
        let after = file.source.replacingOccurrences(of: file.runtime, with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
        #expect(after.count == before.count, "\(before.count) lines became \(after.count)")
    }

    /// The mutated copy is one line, so a comment in it would swallow the rest of the
    /// guard - the closing parenthesis included. Nothing in a mutated copy may begin one.
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

    /// `//` inside a string literal is not a comment, and a refusal that matched on the two
    /// characters could not tell the difference. A URL in a mutated expression cost a
    /// mutant - or, before that, the whole run.
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

    /// A multi-line string literal is the one thing that genuinely cannot be put on one
    /// line: its newlines are part of what it means. That is a skip with a name, counted
    /// and printed by `list --explain`, and not a run that stops.
    @Test("passes over an expression holding a multi-line string, and says so")
    func multilineStringIsASkipRatherThanAStop() throws {
        // A concatenation whose right operand is the literal, so the site a guard would
        // wrap is the whole expression and the literal is inside it. A candidate *within*
        // a multi-line string - in an interpolation - is a different thing and flattens
        // perfectly well, because the literal around it is not part of the copy.
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
