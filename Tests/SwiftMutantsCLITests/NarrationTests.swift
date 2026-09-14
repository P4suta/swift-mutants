// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsValidate
import Testing

@testable import SwiftMutantsCLI

/// What a run says about itself.
///
/// The narration is the whole product for anybody who does not read JSON, and it was the
/// one surface with no test on it: a phase could stop announcing itself, or announce a
/// number that was not true, and every other test in this package would still pass. These
/// hold the words.
@Suite("Narration")
struct NarrationTests {

    @Test("names each phase it passes through")
    func namesEachPhase() {
        #expect(Narration.line(for: .snapshotting) == "copying the package")
        #expect(Narration.line(for: .discovering) == "reading the sources")
        #expect(Narration.line(for: .proving) == "proving every mutant is in the tree")
        #expect(Narration.line(for: .building) == "building the tests, once")
        #expect(Narration.line(for: .baseline) == "running the tests with nothing awake")
    }

    @Test("says how much it instrumented and where")
    func saysWhatItInstrumented() {
        #expect(
            Narration.line(for: .instrumenting(files: 61, mutants: 646))
                == "instrumenting 646 mutants across 61 files"
        )
    }

    /// Every stage must say something or deliberately say nothing. A stage that fell
    /// through to `nil` by accident is a phase that runs silently, which is the failure
    /// mode this narration exists to prevent.
    @Test("leaves no phase silent by accident")
    func nothingIsSilent() {
        let stages: [RunStage] = [
            .snapshotting, .discovering, .instrumenting(files: 1, mutants: 1),
            .validating(.compiling(round: 1, mutants: 1)), .building, .proving, .baseline,
            .calibrated(.seconds(1)), .probing(tests: 1),
            .covered(uncovered: 1, averageTests: 1), .scoped(since: "HEAD", files: 1),
            .remembered(known: 1, total: 1), .unmeasured(tests: 1),
            .recalled(known: 1, total: 1),
            .running(total: 1, processes: 1),
        ]
        for stage in stages {
            #expect(Narration.line(for: stage) != nil, "\(stage) says nothing")
        }
    }

    /// `.finished` is the one stage that is deliberately silent here: it arrives once per
    /// mutant and is counted rather than narrated, because a line each would bury the
    /// handful a person can act on.
    @Test("says nothing for each finished mutant")
    func finishedIsCountedNotSaid() {
        let result = NarrationFixture.result(.survived, tests: [])
        #expect(Narration.line(for: .finished(result)) == nil)
    }
}

/// The lines that carry a number.
@Suite("Narrating numbers")
struct NarrationNumberTests {

    @Test("says where the deadline came from")
    func saysWhereTheDeadlineCameFrom() {
        #expect(
            Narration.line(for: .calibrated(.seconds(37)))
                == "  giving each mutant 37 seconds, from how long that took"
        )
    }

    @Test("says how many tests it asked")
    func saysHowManyTestsItAsked() {
        #expect(
            Narration.line(for: .probing(tests: 610))
                == "asking each of 610 tests what it reaches"
        )
    }

    /// The number that justifies the whole coverage pass: a mutant faces a handful of
    /// tests instead of the suite.
    @Test("says what the coverage bought")
    func saysWhatCoverageBought() {
        #expect(
            Narration.line(for: .covered(uncovered: 74, averageTests: 39.28))
                == "  nothing reaches 74 of them; the rest face 39.3 tests each, "
                + "not the whole suite"
        )
    }

    @Test("rounds an average to one place")
    func roundsToOnePlace() {
        #expect(Narration.oneDecimal(0) == "0.0")
        #expect(Narration.oneDecimal(39.28) == "39.3")
        #expect(Narration.oneDecimal(2.04) == "2.0")
        #expect(Narration.oneDecimal(-1.25) == "-1.3")
    }

    @Test("says what a scoped run is about")
    func saysWhatAScopedRunIsAbout() {
        #expect(
            Narration.line(for: .scoped(since: "main", files: 4))
                == "measuring only what changed since main: 4 files"
        )
    }

    /// Nothing to measure is news, not an empty list. A run that said "measuring 0 files"
    /// and then scored 100% would be read as a pass.
    @Test("says plainly when nothing changed")
    func saysWhenNothingChanged() {
        #expect(
            Narration.line(for: .scoped(since: "main", files: 0))
                == "nothing has changed since main"
        )
    }

    /// The saving, said out loud: a number a reader can check against the run.
    @Test("says how many processes the mutants will take")
    func saysHowManyProcesses() {
        #expect(
            Narration.line(for: .running(total: 671, processes: 96))
                == "running 671 mutants in 96 processes"
        )
    }

    /// A run that has nothing left to run says nothing about running. "running 0 mutants"
    /// is a sentence about work that is not happening, printed directly under the line
    /// that already explained why.
    @Test("says nothing about running when there is nothing to run")
    func nothingToRun() {
        #expect(Narration.line(for: .running(total: 0, processes: 0)) == nil)
    }

    /// With no coverage there is no saving, and claiming one would be a lie a reader has
    /// no way to catch.
    @Test("claims no saving when there is none")
    func claimsNoSavingWhenThereIsNone() {
        #expect(Narration.line(for: .running(total: 671, processes: 671)) == "running 671 mutants")
    }
}

/// What validation says while it runs, which is the slowest and quietest phase there is.
@Suite("Narrating validation")
struct NarrationValidationTests {

    /// "Asking", not "building". A round is every module of the package lowered at once,
    /// separately - not a build - except when the plan cannot be read and it falls back to
    /// one. A word true of only one of those would be a lie half the time.
    @Test("says the first round is about every mutant")
    func firstRound() {
        #expect(
            Narration.validating(.compiling(round: 1, mutants: 646))
                == "asking the compiler about all 646 mutants at once"
        )
    }

    /// A second round is progress, and the count shrinking is the evidence of it. Without
    /// this line a reader cannot tell a second build from a hang.
    @Test("says a later round is smaller")
    func laterRound() {
        #expect(
            Narration.validating(.compiling(round: 2, mutants: 611))
                == "  asking again, 611 left"
        )
    }

    @Test("says how many the compiler refused")
    func refused() {
        #expect(Narration.validating(.refused(round: 1, count: 35)) == "  the compiler refused 35")
    }

    /// Halving is the expensive path, and the reason for it is a diagnostic nobody could
    /// place. Printing that diagnostic is the only way a reader learns why - it exists
    /// only while the tree is instrumented and is gone by the time the run ends.
    @Test("says why it had to halve, in the compiler's words")
    func halvingSaysWhy() {
        let diagnostic = CompilerDiagnostic(
            file: "Sources/Codec/Header.swift",
            position: SourcePosition(line: 12, column: 30),
            severity: .error,
            message: "no such module 'Core'"
        )
        #expect(
            Narration.validating(.halving(mutants: 646, unplaceable: diagnostic))
                == """
                  the compiler would not say which, so halving 646 mutants
                  it said: Sources/Codec/Header.swift:12:30: no such module 'Core'
                """
        )
    }

    @Test("halves without a diagnostic when there is none to give")
    func halvingWithoutOne() {
        #expect(
            Narration.validating(.halving(mutants: 646, unplaceable: nil))
                == "  the compiler would not say which, so halving 646 mutants"
        )
    }
}
