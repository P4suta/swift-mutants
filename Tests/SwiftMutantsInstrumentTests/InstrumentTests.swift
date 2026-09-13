// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsInstrument

/// Putting every compilable mutant into one tree, each dormant behind a guard.
///
/// This is the reason the tool is usable at all. Swift builds are slow, and a mutation run
/// that rebuilt once per mutant would be an overnight job on a package of any size; Muter's
/// open issues about memory exhaustion and hour-long runs are what that looks like. Here the
/// toolchain builds once and one environment variable decides which mutant is awake.
@Suite("Instrument")
struct InstrumentTests {

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func instrument(_ source: String) throws -> InstrumentedFile {
        let discovery = Discover.candidates(in: source, at: Self.path())
        return try Instrument.file(source, discovery: discovery)
    }

    /// The invariant that makes coverage data usable at all: a line in the instrumented
    /// file is the same line in the file the user wrote, so a profile that says "line 14
    /// ran" says it about the same line either way.
    @Test(
        "keeps the file the same number of lines",
        arguments: [
            "func f(_ a: Int, _ b: Int) -> Bool { return a < b }",
            """
            func f(_ a: Int, _ b: Int) -> Bool {
                return a < b
                    && a > b
            }
            """,
            """
            struct S {
                func f(_ a: Bool, _ b: Bool) -> Bool { a && b }
                func g(_ a: Bool, _ b: Bool) -> Bool { a || b }
            }
            """,
        ]
    )
    func preservesLineCount(source: String) throws {
        let instrumented = try Self.instrument(source)
        let before = source.split(separator: "\n", omittingEmptySubsequences: false).count
        let runtimeLines = instrumented.runtimeLineCount
        let after = instrumented.source.split(separator: "\n", omittingEmptySubsequences: false)
            .count
        #expect(
            after - runtimeLines == before,
            "the body grew by \(after - runtimeLines - before) lines"
        )
    }

    /// The runtime goes at the end, so every line above it keeps its number.
    @Test("appends its runtime rather than inserting one")
    func runtimeIsAppended() throws {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { return a < b }"
        let instrumented = try Self.instrument(source)
        let body = instrumented.source.prefix(
            instrumented.source.count - instrumented.runtime.count
        )
        #expect(body.hasPrefix("func f("))
        #expect(instrumented.source.hasSuffix(instrumented.runtime))
    }

    /// A file-local runtime is what lets this work on an Xcode project: nothing has to be
    /// added to a manifest, and no target membership has to be known.
    @Test("keeps its runtime private to the file")
    func runtimeIsFileLocal() throws {
        let instrumented = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        #expect(instrumented.runtime.contains("private let"))
        #expect(instrumented.runtime.contains("private func"))
        #expect(!instrumented.runtime.contains("public"))
        #expect(!instrumented.runtime.contains("import Foundation"))
    }

    /// Muter reads `ProcessInfo.processInfo.environment` inside every guard, which builds a
    /// dictionary from the environment on each evaluation. A guard in a loop pays that
    /// every time round.
    @Test("reads the environment once, not once per guard")
    func environmentIsReadOnce() throws {
        let instrumented = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        #expect(instrumented.runtime.contains("getenv"))
        #expect(!instrumented.source.contains("ProcessInfo"))

        // The call lives in the runtime and nowhere else: a guard is an integer compare
        // against a global that was initialised once.
        let call = "getenv(\"" + "SWIFT_MUTANTS_ACTIVE" + "\")"
        let body = instrumented.source.dropLast(instrumented.runtime.count)
        #expect(!body.contains(call))

        // Twice in the runtime, because it is spelled twice: a package built with
        // -strict-memory-safety needs the call marked `unsafe` and one built without it
        // warns about a mark that was not needed. Only one branch is ever compiled.
        #expect(instrumented.runtime.contains("#if hasFeature(StrictMemorySafety)"))
        #expect(instrumented.runtime.components(separatedBy: call).count == 3)
    }

    @Test("wraps the expression rather than the statement")
    func wrapsTheExpression() throws {
        let instrumented = try Self.instrument(
            "func f(_ a: Int, _ b: Int) -> Bool { return a < b }"
        )
        #expect(instrumented.source.contains("return (__sm"))
        #expect(instrumented.source.contains("? (a <= b) : (a < b))"))
    }

    /// Several rules at one expression are alternatives at one site, chained rather than
    /// nested copies of the surrounding code.
    @Test("chains the mutants of one expression")
    func chainsOneSite() throws {
        let source = "func f(_ a: Bool, _ b: Bool) -> Bool { a && b }"
        let instrumented = try Self.instrument(source)
        #expect(instrumented.mutants.count == 3)
        #expect(instrumented.source.contains("? (a || b) : ("))
        // Three alternatives, one copy of the expression they are alternatives to. Nesting
        // whole copies instead would be exponential in the number of rules at a site.
        let originals = instrumented.source.components(separatedBy: "(a && b)").count - 1
        #expect(originals == 1, "the original was copied per mutant: \(instrumented.source)")
    }

    /// Only one mutant is ever awake, so the mutated side of an outer guard carries the
    /// pristine inner expression rather than a second copy of its guard. That is what keeps
    /// the file growing with the size of the rewritten expressions instead of with the
    /// number of mutants times the size of the file.
    @Test("does not repeat an inner guard inside an outer mutant")
    func nestedSitesDoNotDuplicate() throws {
        let source = "func f(_ a: Int, _ b: Int, _ c: Bool) -> Bool { return a < b && c }"
        let instrumented = try Self.instrument(source)
        // The inner site is the comparison; the outer one is the conjunction around it.
        let inner = try #require(instrumented.mutants.first { $0.rule.name == "lt-to-le" })
        let call = "__sm_\(instrumented.runtimeToken)(\(inner.index) "
        let uses = instrumented.source.components(separatedBy: call).count - 1
        #expect(uses == 1, "the inner guard was duplicated: \(instrumented.source)")
    }

    /// The activation proof looks for these in the built binary. A marker that cannot be
    /// found is a mutant that was never spliced in, which is the failure that made Muter
    /// report four hundred false regressions.
    @Test("gives every mutant a marker that appears in the file exactly once")
    func markersAreUniqueAndPresent() throws {
        let source = """
            func f(_ a: Int, _ b: Int, _ c: Bool) -> Bool {
                return a < b && c || a > b
            }
            """
        let instrumented = try Self.instrument(source)
        #expect(instrumented.mutants.count == 8)
        #expect(Set(instrumented.mutants.map(\.marker)).count == instrumented.mutants.count)
        for mutant in instrumented.mutants {
            let occurrences = instrumented.source.components(separatedBy: mutant.marker).count - 1
            #expect(occurrences == 1, "\(mutant.marker) appears \(occurrences) times")
        }
    }

    @Test("numbers its mutants densely, from zero")
    func indicesAreDense() throws {
        let source = """
            func f(_ a: Int, _ b: Int, _ c: Bool) -> Bool {
                return a < b && c || a > b
            }
            """
        let instrumented = try Self.instrument(source)
        #expect(instrumented.mutants.count == 8)
        #expect(
            instrumented.mutants.map(\.index).sorted() == Array(0..<UInt32(8)),
            "indices must be dense from zero: the runtime reads one integer and compares"
        )
    }

    /// The identity is computed from the original file, not from the instrumented one.
    @Test("names its mutants after the file the user wrote")
    func identitiesComeFromTheOriginal() throws {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { return a < b }"
        let discovery = Discover.candidates(in: source, at: Self.path())
        let instrumented = try Instrument.file(source, discovery: discovery)

        let candidate = try #require(discovery.candidates.first)
        let expected = MutantIdentity(
            MutantIdentity.Inputs(
                path: Self.path(),
                enclosingDeclaration: candidate.enclosingDeclaration,
                rule: candidate.rule,
                span: candidate.span,
                sourceDigest: Digest.of(source),
                originalBytes: Digest.of(candidate.original),
                replacementBytes: Digest.of(candidate.replacement)
            )
        )
        #expect(instrumented.mutants.first?.identity == expected)
    }

    @Test("leaves a file with nothing to mutate exactly as it was")
    func untouchedWhenThereIsNothingToDo() throws {
        let source = "// nothing here\n"
        let instrumented = try Self.instrument(source)
        #expect(instrumented.source == source)
        #expect(instrumented.mutants.isEmpty)
        #expect(instrumented.runtime.isEmpty)
    }
}
