// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsExecute

/// One answer from several bundles.
///
/// A trial used to be one process, because a package used to build one test bundle. It now
/// builds one per test target, so a mutant that several bundles could catch is several
/// processes - and the answer has to read as though it were one, because a mutant has one
/// verdict and a score has one denominator.
///
/// The asymmetry that decides every rule here: `survived` is a claim about every test that
/// could have caught it, so it needs all of them; `killed` is a claim about one, so the
/// first one is enough and the rest are time spent establishing what is established.
@Suite("A verdict across bundles")
struct VerdictAcrossBundlesTests {

    static func verdict(
        _ outcome: Outcome,
        started: [String] = [],
        killedBy: [String] = [],
        milliseconds: Int = 10
    ) -> Verdict {
        Verdict(
            outcome: outcome,
            killedBy: killedBy,
            firstFailure: killedBy.first.map { "\($0) said no" },
            startedTests: started,
            durationMilliseconds: milliseconds,
            termination: .exited(outcome == .survived ? 0 : 1)
        )
    }

    @Test("survives only when every bundle survived")
    func survivesOnlyIfAllDo() {
        let said = Verdict.across([
            Self.verdict(.survived, started: ["A.x()"]),
            Self.verdict(.survived, started: ["B.y()"]),
        ])
        #expect(said.outcome == .survived)
        // Every test that ran, because that is what "nothing noticed" is a claim about.
        #expect(said.startedTests == ["A.x()", "B.y()"])
        #expect(said.durationMilliseconds == 20)
    }

    @Test("is killed as soon as one bundle kills it")
    func killedByOne() {
        let said = Verdict.across([
            Self.verdict(.survived, started: ["A.x()"]),
            Self.verdict(.killed, started: ["B.y()"], killedBy: ["B.y()"]),
        ])
        #expect(said.outcome == .killed)
        #expect(said.killedBy == ["B.y()"])
        #expect(said.firstFailure == "B.y() said no")
        #expect(said.startedTests == ["A.x()", "B.y()"])
    }

    /// A bundle that ran out of time establishes nothing about the ones after it, so the
    /// answer is the deadline rather than the survival of whatever did finish. Counting it
    /// as survived would be reporting a mutant nothing caught when what happened is that
    /// nothing finished looking.
    @Test("reports a deadline rather than the survival of the bundles that did finish")
    func deadlineWins() {
        let said = Verdict.across([
            Self.verdict(.survived, started: ["A.x()"]),
            Self.verdict(.timedOut, started: ["B.y()"]),
        ])
        #expect(said.outcome == .timedOut)
    }

    /// A kill is a fact about the program; a deadline is a fact about how long looking
    /// took. A bundle that caught the mutant has answered the question the deadline was
    /// still asking.
    @Test("prefers a kill to a deadline, whichever came first")
    func killBeatsDeadline() {
        let said = Verdict.across([
            Self.verdict(.timedOut, started: ["A.x()"]),
            Self.verdict(.killed, started: ["B.y()"], killedBy: ["B.y()"]),
        ])
        #expect(said.outcome == .killed)
        #expect(said.killedBy == ["B.y()"])
    }

    /// One bundle, which is every package with one test target and was every package at
    /// all until recently. It has to come back exactly as it went in.
    @Test("hands a single bundle's answer straight back")
    func oneBundleIsItself() {
        let only = Self.verdict(.killed, started: ["A.x()"], killedBy: ["A.x()"], milliseconds: 7)
        #expect(Verdict.across([only]) == only)
    }

    /// No bundles at all is not an answer about a program. It means the caller worked out
    /// that nothing could run and started nothing, and reporting that as `survived` would
    /// put a mutant nobody measured into the numerator's denominator.
    @Test("refuses to call no bundles at all a survival")
    func noBundlesIsNotSurvival() {
        #expect(Verdict.across([]).outcome == .errored)
    }
}
