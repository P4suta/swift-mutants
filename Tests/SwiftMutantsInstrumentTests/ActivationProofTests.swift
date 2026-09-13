// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsInstrument

/// Never infer that instrumentation happened.
///
/// Muter kept its mutation sites keyed on syntax-node identity, re-parsed each file before
/// splicing them in, matched no keys, inserted zero mutants, and reported four hundred
/// previously-killed mutants as newly surviving - with a clean build and no crash. That is
/// the failure this exists to make impossible rather than unlikely.
@Suite("Activation proof")
struct ActivationProofTests {

    static func instrument(_ source: String) throws -> InstrumentedFile {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return try Instrument.file(source, discovery: Discover.candidates(in: source, at: path))
    }

    @Test("proves a properly instrumented file")
    func provesAGoodFile() throws {
        let file = try Self.instrument(
            """
            func f(_ a: Int, _ b: Int, _ c: Bool) -> Bool {
                return a < b && c || a > b
            }
            """
        )
        let proof = ActivationProof.inSource(file)
        #expect(proof.isProved)
        #expect(proof.expected == 8)
        #expect(proof.found == 8)
    }

    /// The #307 shape exactly: the mutants are known about and none of them is in the file.
    @Test("refuses a file whose mutants were never spliced in")
    func refusesAFileWithNoMutantsInIt() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        let pretending = InstrumentedFile(
            // The original text, with the mutants still claimed.
            source: "func f(_ a: Int, _ b: Int) -> Bool { a < b }",
            runtime: file.runtime,
            mutants: file.mutants,
            runtimeToken: file.runtimeToken
        )
        let proof = ActivationProof.inSource(pretending)
        #expect(!proof.isProved)
        #expect(proof.found == 0)
        #expect(proof.absences.first?.occurrences == 0)
        #expect(proof.absences.first?.identity == file.mutants.first?.identity)
    }

    /// Twice is as wrong as never. Two guards sharing an index means activating one wakes
    /// both, and the run attributes a kill to whichever mutant it happened to be asking
    /// about.
    @Test("refuses a marker that appears more than once")
    func refusesADuplicatedMarker() throws {
        let file = try Self.instrument("func f(_ a: Int, _ b: Int) -> Bool { a < b }")
        let doubled = InstrumentedFile(
            source: file.source + file.source,
            runtime: file.runtime,
            mutants: file.mutants,
            runtimeToken: file.runtimeToken
        )
        let proof = ActivationProof.inSource(doubled)
        #expect(!proof.isProved)
        #expect(proof.absences.first?.occurrences == 2)
    }

    @Test("proves nothing, happily, when there was nothing to prove")
    func emptyIsProved() throws {
        let proof = ActivationProof.inSource(try Self.instrument("// nothing\n"))
        #expect(proof.isProved)
        #expect(proof.expected == 0)
    }

    /// The other way to end up measuring a program with no mutants in it: the file was
    /// spliced and then never compiled into the thing that runs.
    @Test("notices an instrumented file that did not reach the product")
    func noticesAFileLeftOutOfTheBuild() {
        let symbols = """
            0000000100003a10 T _$s7Subject8classifyySSSi_SitF
            0000000100008000 b ___sm_active_aaaaaaaaaaaa
            """
        #expect(ActivationProof.missingTokens(["aaaaaaaaaaaa"], inSymbols: symbols).isEmpty)
        #expect(
            ActivationProof.missingTokens(
                ["aaaaaaaaaaaa", "bbbbbbbbbbbb"],
                inSymbols: symbols
            ) == ["bbbbbbbbbbbb"]
        )
    }

    @Test("has nothing to say about a file that needed no runtime")
    func noRuntimeMeansNoToken() {
        #expect(ActivationProof.missingTokens([""], inSymbols: "").isEmpty)
    }
}
