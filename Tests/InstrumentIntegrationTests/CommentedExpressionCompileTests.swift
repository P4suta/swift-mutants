// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsInstrument

/// The compiler's opinion of an expression whose comment was taken out of the mutated copy.
///
/// The unit tier can say the copy holds no `//` and that the file is the same number of
/// lines. Only the compiler can say the result is still the program - that taking a comment
/// out did not take a token with it, and that what is left parses as one expression on one
/// line. That is the claim, so this is where it is checked.
///
/// Reported from a package with 87 commented expressions across 32 files, where each of
/// four runs stopped on one of them after the whole instrument-and-validate pass. Every one
/// was a comment explaining an argument at the argument, which is what comments are for.
@Suite("Compiling an expression whose comment came out", .tags(.integration))
struct CommentedExpressionCompileTests {

    static func compiles(_ source: String) throws -> (exitCode: Int32, text: String) {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        let discovery = Discover.candidates(in: source, at: path)
        // Refuses to let any of this pass because nothing was tested. A comment three
        // lines above an operator is not inside the site a guard wraps for it, so a
        // fixture shaped that way is instrumented without a copy ever holding a comment -
        // and every test here passes however the flattening is written. The first version
        // of this suite was shaped that way, and perturbing the removal left it green.
        #expect(
            discovery.lineComments.contains { comment in
                discovery.candidates.contains {
                    $0.guardSpan.start <= comment.start && comment.end <= $0.guardSpan.end
                }
            },
            "no site in this fixture holds a comment, so nothing here is being compiled")
        let instrumented = try Instrument.file(source, discovery: discovery)
        return try InlinableTests.compile(["Subject.swift": instrumented.source])
    }

    @Test("compiles an argument list with a comment in the middle of it")
    func commentedArgument() throws {
        let said = try Self.compiles(
            """
            struct Thing { let label: String; let count: Int }

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
            """)
        #expect(said.exitCode == 0, "\(said.text)")
    }

    /// A comment at the end of a line that carries code, which is where the tokens either
    /// side of it are closest together and a careless removal shows up soonest.
    @Test("compiles a trailing comment beside the code it is about")
    func trailingComment() throws {
        let said = try Self.compiles(
            """
            func names(_ first: [String]) -> [String] {
                first  // the caller's own, which come before anything we add
                    + ["ours"]
            }
            """)
        #expect(said.exitCode == 0, "\(said.text)")
    }

    /// Two slashes in a string are not a comment, and taking them out would break the
    /// program rather than tidy it.
    @Test("compiles an expression holding a URL")
    func urlInAString() throws {
        let said = try Self.compiles(
            """
            func url(_ host: String, _ path: String) -> String {
                "https://"  // the scheme, which this never varies
                    + host + "/" + path
            }
            """)
        #expect(said.exitCode == 0, "\(said.text)")
    }

    /// A documentation comment inside an expression is rare and legal, and runs to the end
    /// of its line exactly as an ordinary one does.
    @Test("compiles an expression holding a documentation comment")
    func docComment() throws {
        let said = try Self.compiles(
            """
            func sizes(_ base: [Int], _ n: Int) -> [Int] {
                base
                    /// the double, which the layout uses for retina
                    + [n * 2]
            }
            """)
        #expect(said.exitCode == 0, "\(said.text)")
    }
}
