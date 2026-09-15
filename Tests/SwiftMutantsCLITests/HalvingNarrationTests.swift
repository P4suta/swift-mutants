// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsEngine
import SwiftMutantsValidate
import Testing

@testable import SwiftMutantsCLI

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
        let text = "/tmp/pkg/Hot.swift:107:16: \(severity): \(message)"
        let parsed = CompilerDiagnostic.parse(text)
        return Narration.validating(
            .halving(mutants: 255, read: parsed.count, unplaceable: parsed.first))
    }

    /// Whose failure this is.
    ///
    /// "The compiler would not say which" is two different pieces of news and used to be
    /// one sentence. If the compiler wrote diagnostics and none landed on a mutant, that is
    /// a fact about the program - a `missing return` at a closing brace, an error inside a
    /// macro buffer. If this read *no* diagnostics at all out of a compile that failed,
    /// that is this tool's own parser, and saying only "would not say which" sends somebody
    /// to look at their own code for a defect in here.
    ///
    /// Not hypothetical: when SwiftPM began emitting colour, every diagnostic parsed as
    /// nothing and every package fell into halving. From outside, that was indistinguishable
    /// from a package whose errors genuinely belonged nowhere. Reported again from a package
    /// where five runs in a row took the fallback, one of them for 130 compiles and an hour.
    @Test("says it could read nothing, rather than that nothing could be placed")
    func readNothingIsItsOwnNews() {
        let said = Narration.validating(.halving(mutants: 3222, read: 0, unplaceable: nil))
        #expect(said.contains("3222"))
        #expect(
            said.lowercased().contains("could not read")
                || said.lowercased().contains("read none"),
            "\(said)")
    }

    /// And when it did read them, how many - so a reader can tell "one stray error" from
    /// "forty of them, none of which are mine".
    @Test("says how many it read when none of them were at a mutant")
    func saysHowManyItRead() {
        let parsed = CompilerDiagnostic.parse(
            "/tmp/pkg/A.swift:1:1: error: one\n/tmp/pkg/A.swift:2:1: error: two")
        let said = Narration.validating(
            .halving(mutants: 9, read: parsed.count, unplaceable: parsed.first))
        #expect(said.contains("\(parsed.count)"), "\(said)")
    }

    /// The two must not read alike, because they send somebody to different places.
    @Test("does not say the same thing for both")
    func theTwoDiffer() {
        #expect(
            Narration.validating(.halving(mutants: 9, read: 0, unplaceable: nil))
                != Self.said("missing return in a function"))
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
        let said = Narration.validating(.halving(mutants: 42, read: 0, unplaceable: nil))
        #expect(said.contains("42"))
        #expect(!said.contains("the first:"))
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
