// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsEngine
import Testing

@testable import SwiftMutantsCLI

/// What a finished run exits with.
///
/// The number is the only part of a run a build system reads, so what it means has to be
/// fixed rather than incidental. Zero is "this answered the question". One is a gate
/// somebody asked for, and nothing else - a run that found survivors has not failed, and a
/// tool that exited non-zero for answering is a tool people stop running. Two is this tool
/// or this configuration being wrong, which is not the same news and must not be reachable
/// by having a low score.
@Suite("What a run exits with")
struct GateTests {

    static func expectation(_ reason: String = "unreachable") -> Configuration.Expectation {
        Configuration.Expectation(identity: String(repeating: "a", count: 64), reason: reason)
    }

    static func verdict(
        met: Int = 0, contradicted: Int = 0, stale: Int = 0, superseded: Int = 0
    ) -> Expectations.Verdict {
        Expectations.Verdict(
            met: met,
            contradicted: (0..<contradicted).map { _ in
                Expectations.Contradiction(expectation: Self.expectation(), reason: "caught")
            },
            stale: (0..<stale).map { _ in Self.expectation() },
            superseded: (0..<superseded).map { _ in Self.expectation() }
        )
    }

    static func summary(survived: Int, expected: Int = 0) -> RunSummary {
        guard
            let summary = RunSummary(
                killed: 1,
                survived: survived,
                timedOut: 0,
                inconclusive: 0,
                errored: 0,
                notRun: 0,
                rejected: 0,
                equivalent: 0,
                uncovered: 0,
                cached: 0,
                expectedSurvivors: expected
            )
        else { fatalError("malformed fixture tally") }
        return summary
    }

    @Test("exits zero for a run that answered")
    func answeredIsZero() {
        #expect(Gate.exitCode(survivors: 3, expectations: .unasked, strict: false) == nil)
    }

    @Test("exits one for the gate somebody asked for")
    func strictIsOne() {
        #expect(Gate.exitCode(survivors: 3, expectations: .unasked, strict: true) == 1)
    }

    @Test("exits zero under the gate when nothing survived")
    func strictPassesOnZero() {
        #expect(Gate.exitCode(survivors: 0, expectations: .unasked, strict: true) == nil)
    }

    /// A survivor somebody wrote down is not a survivor the gate is about. Otherwise a
    /// project could never both use `--strict` and account for a mutant that cannot be
    /// caught - which is exactly the pair of things expectations exist to allow.
    @Test("does not fail the gate for a survivor that was expected")
    func expectedSurvivorsLeaveTheGate() {
        let counted = Gate.survivors(of: Self.summary(survived: 2, expected: 2))
        #expect(counted == 0)
        #expect(Gate.exitCode(survivors: counted, expectations: .unasked, strict: true) == nil)
    }

    @Test("still fails the gate for the survivors nobody wrote down")
    func unexpectedSurvivorsStillFail() {
        #expect(Gate.survivors(of: Self.summary(survived: 3, expected: 2)) == 1)
    }

    /// A configuration that has become untrue is the tool being lied to, not a low score,
    /// so it is two - and it is two whether or not anybody asked for a gate.
    @Test("exits two for an expectation the run disagreed with")
    func contradictionIsTwo() {
        #expect(
            Gate.exitCode(
                survivors: 0, expectations: Self.verdict(contradicted: 1), strict: false) == 2)
    }

    @Test("exits two for an expectation whose mutant is gone")
    func stalenessIsTwo() {
        #expect(
            Gate.exitCode(survivors: 0, expectations: Self.verdict(stale: 1), strict: false) == 2)
    }

    /// Two wins. A run that is both wrong about its configuration and over the gate has one
    /// thing to fix first, and a `1` would send somebody to write tests for a mutant whose
    /// identity does not exist any more.
    @Test("says two rather than one when both are true")
    func twoBeatsOne() {
        #expect(
            Gate.exitCode(
                survivors: 5, expectations: Self.verdict(contradicted: 1), strict: true) == 2)
    }

    /// Met and superseded expectations are news, not failures.
    @Test("exits zero for expectations that were met or are no longer needed")
    func metAndSupersededAreZero() {
        #expect(
            Gate.exitCode(
                survivors: 0, expectations: Self.verdict(met: 3, superseded: 2), strict: true)
                == nil)
    }
}

/// What a run exits with when a project's own mutant stopped applying.
///
/// The same news as an expectation naming a mutant that no longer exists, and the same
/// exit. A row whose anchor has moved is a measurement silently not taken: somebody
/// carries on believing they have coverage they do not, and believes it specifically about
/// the code they just changed.
///
/// Reported by somebody who hit ten of these in one session of refactoring - four when they
/// split a file, four more when they moved an extension - and said the sharpness was right:
/// the refactoring cost is real and small, and it lands at the moment they still remember
/// why they moved the code.
@Suite("What a run exits with for a row that stopped applying")
struct UnanchoredGateTests {

    static func stale(_ count: Int) -> [UnanchoredMutant] {
        (0..<count).map {
            UnanchoredMutant(
                row: CustomMutant(find: "gone\($0)()", replace: "x", reason: "reason \($0)"),
                occurrences: 0
            )
        }
    }

    @Test("exits two for one that could not be anchored")
    func staleIsTwo() {
        #expect(
            Gate.exitCode(
                survivors: 0, expectations: .unasked, unanchored: Self.stale(1), strict: false)
                == 2)
    }

    @Test("exits zero when every one anchored")
    func noneIsZero() {
        #expect(
            Gate.exitCode(
                survivors: 0, expectations: .unasked, unanchored: [], strict: false) == nil)
    }

    /// Two beats one, for the reason it beats it everywhere: a run that is over the gate
    /// *and* has a row that stopped applying has one thing to fix first, and exiting `1`
    /// would send somebody to write tests while a measurement is missing.
    @Test("says two rather than one when both are true")
    func twoBeatsOne() {
        #expect(
            Gate.exitCode(
                survivors: 5, expectations: .unasked, unanchored: Self.stale(1), strict: true)
                == 2)
    }
}
