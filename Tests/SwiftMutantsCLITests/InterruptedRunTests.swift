// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsReport
import Testing

@testable import SwiftMutantsCLI

/// What to say when the last run did not get to the end.
///
/// A report is written once, when a run finishes, so `report latest` for an interrupted run
/// said the same thing it says for a package nobody has ever measured: nothing has been
/// measured here yet. That is not true and it is the least useful thing it could say - the
/// answers exist, they were written down as they arrived, and somebody has just lost an hour
/// finding out that they cannot see them.
///
/// Reported from a package of 755 mutants stopped for memory pressure at 755 of 755: every
/// answer was in, and the output was the same as never having started.
@Suite("An interrupted run's account of itself")
struct InterruptedRunTests {

    static func answers(_ count: Int, killed: Int) -> [Ledger.Answer] {
        (0..<count).map { position in
            Ledger.Answer(
                identity: String(repeating: "\(position % 10)", count: 64),
                path: "Sources/A.swift",
                rule: "lt-to-le@1",
                outcome: position < killed ? "killed" : "survived",
                killedBy: position < killed ? ["P.S/f()"] : [],
                durationMilliseconds: 10
            )
        }
    }

    /// Nothing measured and nothing finished are different pieces of news, and only one of
    /// them is worth an hour of somebody's afternoon.
    @Test("says a run was interrupted rather than that nothing was measured")
    func saysItWasInterrupted() {
        let said = Narration.interrupted(Self.answers(755, killed: 318)) ?? ""
        #expect(said.contains("755"), "\(said)")
        #expect(said.lowercased().contains("did not finish"), "\(said)")
    }

    /// With what it had, because that is the point of having kept it.
    @Test("says what it had got to")
    func saysWhatItHad() {
        let said = Narration.interrupted(Self.answers(755, killed: 318)) ?? ""
        #expect(said.contains("318"), "\(said)")
    }

    /// And it is not a score. A score has a denominator - the mutants a run decided not to
    /// count, the ones it never reached - and an interrupted run has none of that. Printing
    /// a percentage from a prefix would be printing a number nobody measured.
    @Test("puts no score on a run that did not finish")
    func noScore() {
        let said = Narration.interrupted(Self.answers(755, killed: 318)) ?? ""
        #expect(!said.contains("%"), "\(said)")
    }

    /// Nothing at all when there is nothing, which is every package nobody has measured.
    @Test("says nothing when there is nothing to say")
    func nothingKept() {
        #expect(Narration.interrupted([]) == nil)
    }
}
