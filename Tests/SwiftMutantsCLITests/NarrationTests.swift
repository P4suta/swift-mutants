// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
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

    /// One share of three, for the stage that carries one.
    static var share: Shard {
        guard let shard = Shard(1, of: 3) else { fatalError("malformed fixture share") }
        return shard
    }

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
                == "instrumenting 646 mutants across 61 files with mutants in them"
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
            .recalled(known: 1, total: 1), .sharded(Self.share, mine: 1, total: 1),
            .provingEquivalence(survivors: 1), .proved(equivalent: 1, duplicates: 0),
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

    /// The widest case, and it has to say so. A mutant the probe narrowed to a handful
    /// of tests gets far less than this - and a line reading "each mutant" while most of
    /// them got a fraction of it would have a reader comparing their run against a number
    /// nothing in it used.
    @Test("says where the deadline came from, and who gets it")
    func saysWhereTheDeadlineCameFrom() {
        let said = Narration.line(for: .calibrated(.seconds(37)))
        #expect(said?.contains("37 seconds") == true, "\(said ?? "nothing")")
        #expect(said?.contains("nothing narrows") == true, "\(said ?? "nothing")")
        #expect(said?.contains("each mutant") != true, "\(said ?? "nothing")")
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

/// What a run says when the compiler would not place a refusal.
///
/// Two sentences, because it is two different pieces of news. "The compiler refused N" is
/// about the mutants and there is nothing for anybody to do. "The compiler ran out of
/// budget" is about *their* code - an expression that type-checks fine as written and tips
/// over once guards wrap its subexpressions - and breaking it into statements is usually an
/// improvement they wanted anyway.
///
/// Reported from a real package: twice in three runs, both times a genuine finding about
/// the package, and both times it arrived reading like a mutant that was not valid Swift.
@Suite("Narrating a halving")
struct HalvingNarrationTests {

    static func said(_ message: String, severity: String = "error") -> String {
        let parsed = CompilerDiagnostic.parse("/tmp/pkg/Hot.swift:107:16: \(severity): \(message)")
        return Narration.validating(.halving(mutants: 255, unplaceable: parsed.first))
    }

    @Test("says how many it is about to halve, and what the compiler said")
    func saysTheCount() {
        let said = Self.said("binary operator '-' cannot be applied to two 'String' operands")
        #expect(said.contains("255"))
        #expect(said.contains("Hot.swift:107:16"))
        #expect(said.contains("binary operator"))
    }

    /// The one that is about their code says so, rather than reading like a refusal.
    @Test("says when the compiler ran out of budget rather than refusing")
    func saysWhenUnaffordable() {
        let said = Self.said(
            "the compiler is unable to type-check this expression in reasonable time; "
                + "try breaking up the expression into distinct sub-expressions")
        #expect(said.contains("too expensive"))
        #expect(said.contains("Hot.swift:107:16"))
        // And it says what to do, because there is something to do.
        #expect(said.lowercased().contains("statement") || said.lowercased().contains("break"))
    }

    /// An ordinary refusal does not get that sentence, or it would be advice about nothing.
    @Test("says nothing about expense when the compiler simply refused")
    func ordinaryRefusalIsPlain() {
        #expect(
            !Self.said("missing return in a function expected to return 'Bool'")
                .contains("too expensive"))
    }

    /// A compile that failed while saying nothing at all still says how many it is halving.
    @Test("still says how many when the compiler said nothing")
    func saidNothing() {
        let said = Narration.validating(.halving(mutants: 42, unplaceable: nil))
        #expect(said.contains("42"))
        #expect(!said.contains("it said"))
    }
}

/// Two counts of files, in two phases, that a reader has to be able to tell apart.
///
/// `list` says how many files it read; the run says how many it instrumented, and the
/// second is smaller because a file with nothing to mutate is not instrumented. Read side
/// by side as bare "N files" they look like the same quantity disagreeing, and a reader
/// briefly concludes that sixteen files went missing between the phases. Reported by
/// somebody who did exactly that.
@Suite("Counting files")
struct FileCountNarrationTests {

    @Test("says what the files it instrumented are a count of")
    func instrumentedSaysWhich() {
        let said = Narration.line(for: .instrumenting(files: 122, mutants: 2256)) ?? ""
        #expect(said.contains("122"))
        #expect(said.contains("2256"))
        // Not a bare "files", which is the half of the pair that misleads.
        #expect(said.contains("files with mutants") || said.contains("files that have"))
    }

    /// And a file with nothing in it is the reason the two differ, so the line says so
    /// rather than leaving a reader to work it out from two numbers in two phases.
    @Test("does not call it a plain count of files")
    func notAPlainCount() {
        let said = Narration.line(for: .instrumenting(files: 1, mutants: 1)) ?? ""
        #expect(!said.hasSuffix("1 files"))
    }
}

/// What a run says about a row of its own that stopped applying.
///
/// The message somebody acts on. Reported by an author who hit ten of these in one session
/// of refactoring: the thing that made each a two-minute fix rather than a hunt was being
/// told *which* row, by what it says. "hold frames until the memory runs out" identifies it
/// instantly; a span identifies nothing and a digest less than that.
///
/// And the count, because the two failures want opposite fixes: none means the code moved
/// and the row needs re-anchoring, more than one means the anchor is too short.
@Suite("Narrating a row that stopped applying")
struct UnanchoredNarrationTests {

    static func row(_ find: String, _ reason: String, found: Int) -> UnanchoredMutant {
        UnanchoredMutant(
            row: CustomMutant(find: find, replace: "x", reason: reason),
            occurrences: found
        )
    }

    static func lines(_ rows: [UnanchoredMutant]) -> [String] {
        Narration.unanchored(rows)
    }

    @Test("says nothing when every row anchored")
    func silentWhenFine() {
        #expect(Self.lines([]).isEmpty)
    }

    /// By what it says, which is the whole point.
    @Test("names the row by what it says")
    func namesTheRow() {
        let said = Self.lines([
            Self.row(
                "input.isReadyForMoreMediaData", "hold frames until the memory runs out", found: 0)
        ]).joined(separator: "\n")
        #expect(said.contains("hold frames until the memory runs out"))
        #expect(said.contains("input.isReadyForMoreMediaData"))
    }

    /// The two failures read differently, because they want different fixes.
    @Test("tells a moved anchor from a short one")
    func tellsThemApart() {
        let moved = Self.lines([Self.row("gone()", "a reason", found: 0)]).joined(separator: "\n")
        let short = Self.lines([Self.row("wrong", "a reason", found: 4)]).joined(separator: "\n")
        #expect(moved != short)
        #expect(short.contains("4"))
        #expect(moved.lowercased().contains("moved") || moved.lowercased().contains("not there"))
    }

    /// All of them, because somebody fixing ten after a refactor wants the list rather than
    /// ten runs.
    @Test("says every one of them")
    func saysAllOfThem() {
        let said = Self.lines([
            Self.row("one()", "first reason", found: 0),
            Self.row("two()", "second reason", found: 0),
        ]).joined(separator: "\n")
        #expect(said.contains("first reason"))
        #expect(said.contains("second reason"))
    }

    /// And says what it means, because a reader seeing this for the first time has to know
    /// why a row not applying is worth stopping for.
    @Test("says why it matters")
    func saysWhyItMatters() {
        let said = Self.lines([Self.row("gone()", "a reason", found: 0)]).joined(separator: "\n")
        #expect(said.lowercased().contains("measur") || said.lowercased().contains("test"))
    }
}
