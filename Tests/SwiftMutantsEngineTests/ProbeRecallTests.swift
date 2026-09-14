// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCache
import SwiftMutantsCore
import SwiftMutantsExecute
import Testing

@testable import SwiftMutantsEngine

/// What a run has the next one believe about which tests run what.
///
/// The dangerous entry is the one that looks like an answer and is not. A probe that did not
/// finish establishes nothing, and writing that down as an empty reach would hide the same
/// mutant from every later run - the mistake the probe already refuses to make, one run
/// further on and much harder to see.
@Suite("What a run writes down about its probes")
struct ProbeRecallTests {

    static func path(_ name: String) -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/\(name).swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static let code = Self.path("A")
    static let tests = Self.path("ATests")

    static let digests: [WorkspaceRelativePath: Digest] = [
        code: Digest.of("A"), tests: Digest.of("ATests"),
    ]

    static func catalogue() -> MutantCatalogue {
        MutantCatalogue(files: [1: Self.code], identities: [1: Self.identity])
    }

    static let identity = MutantIdentity(
        MutantIdentity.Inputs(
            path: Self.code,
            enclosingDeclaration: "s:7Example1fyySiF",
            rule: Self.rule,
            span: Self.span,
            sourceDigest: Digest.of("a < b"),
            originalBytes: Digest.of("<"),
            replacementBytes: Digest.of("<=")
        ))

    static var rule: RuleIdentifier {
        guard let rule = RuleIdentifier("lt-to-le@1") else { fatalError("malformed rule") }
        return rule
    }

    static var span: SourceSpan {
        guard let span = SourceSpan(start: 10, end: 11) else { fatalError("malformed span") }
        return span
    }

    static func memory(of coverage: Coverage) -> ProbeMemory {
        Run.memory(
            of: coverage,
            observable: [Self.code],
            catalogue: Self.catalogue(),
            digests: Self.digests
        )
    }

    @Test("writes down what a test was seen to run")
    func writesWhatItSaw() {
        let memory = Self.memory(
            of: Coverage(byMutant: [1: ["t"]], tests: ["t"], reach: ["t": [1]]))
        #expect(
            memory.reach(of: "t", observable: [Self.code], digests: Self.digests)
                == [Self.identity.digest])
    }

    /// The one that matters. Nothing was established about this test, so nothing is written
    /// down - and the next run asks it again rather than believing it reaches nothing.
    @Test("writes nothing down about a test it could not measure")
    func writesNothingAboutTheUnmeasured() {
        let memory = Self.memory(
            of: Coverage(
                byMutant: [:], tests: ["t"], reach: ["t": []], untrusted: ["t"]))
        #expect(memory.reach(of: "t", observable: [Self.code], digests: Self.digests) == nil)
        #expect(memory.isEmpty)
    }

    /// And it keeps the tests it did measure in the same run.
    @Test("keeps the tests it did measure beside the one it did not")
    func keepsTheRest() {
        let memory = Self.memory(
            of: Coverage(
                byMutant: [1: ["t"]],
                tests: ["t", "u"],
                reach: ["t": [1], "u": []],
                untrusted: ["u"]
            ))
        #expect(memory.count == 1)
        #expect(memory.reach(of: "t", observable: [Self.code], digests: Self.digests) != nil)
    }

    /// A test that really does reach nothing is a finding, and it is written down as one:
    /// the next run does not have to ask again to learn nothing.
    @Test("writes down that a test reaches nothing")
    func nothingIsWorthWritingDown() {
        let memory = Self.memory(
            of: Coverage(byMutant: [:], tests: ["t"], reach: ["t": []]))
        #expect(
            memory.reach(of: "t", observable: [Self.code], digests: Self.digests)?.isEmpty == true)
    }
}
