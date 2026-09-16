// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsRunner
import Testing

@testable import SwiftMutantsEngine

/// A suite that does not agree with itself.
///
/// Every verdict this tool produces rests on one premise: that the tests give the same
/// answer about the same program twice. A suite with one flaky test breaks that premise for
/// the whole run - a mutant is "killed" by a failure that had nothing to do with it, and
/// the score is a number about the weather.
///
/// The baseline is where that is findable, and until now it was measured once. `baseline_runs`
/// was read out of the settings file, validated, stored, and used by nothing.
///
/// Worse than doing nothing: a flaky suite that happened to fail on the one measurement was
/// reported as *"the instrumented tree does not behave like the one you wrote"* - this tool
/// accusing itself of a bug it does not have, and sending somebody to read an instrumented
/// diff that is fine. Naming the flicker is the difference between an hour of that and a
/// sentence.
@Suite("A suite that does not agree with itself")
struct FlickerTests {

    static func verdict(_ outcome: Outcome, tests: [String] = ["S/a()"]) -> Verdict {
        Verdict(
            outcome: outcome,
            killedBy: outcome == .killed ? tests : [],
            firstFailure: outcome == .killed ? tests.first : nil,
            startedTests: tests,
            durationMilliseconds: 1,
            termination: .exited(outcome == .survived ? 0 : 1)
        )
    }

    /// Agreeing is the ordinary case and says nothing at all.
    @Test("says nothing when every measurement agreed")
    func agrees() {
        #expect(Run.flicker(in: [Self.verdict(.survived), Self.verdict(.survived)]) == nil)
    }

    /// One measurement cannot disagree with anything, which is what was wrong before.
    @Test("says nothing about a single measurement")
    func single() {
        #expect(Run.flicker(in: [Self.verdict(.survived)]) == nil)
    }

    @Test("says so when the outcomes disagreed")
    func disagrees() {
        let said = Run.flicker(in: [Self.verdict(.survived), Self.verdict(.killed)])
        #expect(said != nil)
    }

    /// And names the tests, because "your suite is flaky" is not something anybody can act
    /// on and "this test failed on one run of three" is.
    @Test("names the tests that did not agree")
    func namesThem() {
        let said =
            Run.flicker(in: [
                Self.verdict(.survived),
                Self.verdict(.killed, tests: ["S/sometimes()"]),
            ]) ?? ""
        #expect(said.contains("sometimes()"), "\(said)")
    }

    /// Says how often, because once in twenty and nineteen in twenty are the same word and
    /// very different problems.
    @Test("says how many measurements disagreed")
    func saysHowMany() {
        let said =
            Run.flicker(in: [
                Self.verdict(.survived), Self.verdict(.survived),
                Self.verdict(.killed, tests: ["S/sometimes()"]),
            ]) ?? ""
        #expect(said.contains("1") && said.contains("3"), "\(said)")
    }

    /// The point of saying it: it is not this tool's doing, and the sentence that used to
    /// be printed said it was.
    @Test("says whose it is, because the sentence it replaces blamed this tool")
    func saysWhose() {
        let said =
            Run.flicker(in: [Self.verdict(.survived), Self.verdict(.killed)])?.lowercased() ?? ""
        #expect(
            said.contains("flak") || said.contains("agree") || said.contains("same answer"),
            "\(said)")
    }

    /// A baseline that failed every time is not flicker. It is a red baseline, which has
    /// its own answer and its own three sentences, and calling it flaky would send somebody
    /// hunting for a race that is not there.
    @Test("is not what a baseline that always failed is called")
    func alwaysRed() {
        #expect(Run.flicker(in: [Self.verdict(.killed), Self.verdict(.killed)]) == nil)
    }
}
