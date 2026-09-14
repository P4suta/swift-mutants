// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import Testing

@testable import SwiftMutantsValidate

/// Cornering refusals the compiler would not place, across a package rather than a file.
///
/// The fallback path, and the one whose defects are hardest to see: it only runs when a
/// compile has already failed to explain itself, so a wrong answer here arrives looking
/// exactly like a right one.
@Suite("Bisection")
struct BisectionTests {

    typealias Stub = ValidatorTests.Stub

    static func scratch() throws -> ValidatorTests.Scratch { try ValidatorTests.scratch() }

    static func subject(_ source: String, named name: String) -> FileUnderValidation {
        ValidatorTests.subject(source, named: name)
    }

    /// Halving one file while the others keep every mutant asks a question nobody wanted
    /// the answer to. The answer is "no" whenever *any* file holds a refused mutant, and
    /// the innocent file being narrowed is what gets blamed. Measured on this repository
    /// the first time it ran: five refused mutants across four files, and the accusation
    /// landed on a fifth that was fine.
    @Test("blames the file the refused mutant is actually in")
    func blamesTheRightFile() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        // Refused in the second file, and unplaceable so the loop has to halve for it.
        let compiler = Stub(refusing: [], refusingSilently: ["a >= b"])

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([
                Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b }", named: "One.swift"),
                Self.subject("func g(_ a: Int, _ b: Int) -> Bool { a > b }", named: "Two.swift"),
            ])

        #expect(validated.bisected)
        #expect(validated.rejected.map(\.rule.name) == ["gt-to-ge"])
        // The innocent file keeps everything it had.
        let one = try #require(validated.files.first)
        #expect(one.instrumented.mutants.map(\.rule.name) == ["lt-to-le"])
    }

    /// An error nobody can place still names a file. `missing return` is reported at a
    /// closing brace, nowhere near the mutant that removed the return - but it is reported
    /// in the file that mutant is in. Halving that file's candidates costs a compile per
    /// halving of a handful rather than of the whole catalogue.
    @Test("halves the file the compiler complained about, not the whole catalogue")
    func halvesTheNamedFile() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: [], complainingAbout: ["c >= d"])

        let subjects =
            (1...6).map { index in
                Self.subject(
                    "func f\(index)(_ a: Int, _ b: Int) -> Bool { a < b && a > b }",
                    named: "File\(index).swift")
            } + [Self.subject("func g(_ c: Int, _ d: Int) -> Bool { c > d }", named: "Named.swift")]

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate(subjects)

        #expect(validated.rejected.map(\.rule.name) == ["gt-to-ge"])
        // Six files of five mutants each stay out of the search entirely. Halving all
        // thirty-one would be about thirteen compiles; halving the one is about four.
        #expect(compiler.compiles <= 8, "halved \(compiler.compiles) times")
    }

    /// When the named file explains nothing, the search widens rather than giving up.
    @Test("widens to everything when the file it was pointed at is innocent")
    func widensWhenNarrowFails() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        // The refused mutant is in the first file and the complaint names the second.
        let compiler = Stub(
            refusing: [], complainingAbout: ["a <= b"], blaming: "Two.swift")

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([
                Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b }", named: "One.swift"),
                Self.subject("func g(_ c: Int, _ d: Int) -> Bool { c > d }", named: "Two.swift"),
            ])

        #expect(validated.rejected.map(\.rule.name).contains("lt-to-le"))
    }

    /// Several refused mutants spread across several files, none of them placeable.
    @Test("corners refusals in more than one file at once")
    func acrossSeveralFiles() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: [], refusingSilently: ["a <= b", "c >= d"])

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([
                Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b }", named: "One.swift"),
                Self.subject("func g(_ c: Int, _ d: Int) -> Bool { c > d }", named: "Two.swift"),
                Self.subject("func h(_ e: Int, _ f: Int) -> Bool { e < f }", named: "Three.swift"),
            ])

        #expect(validated.rejected.map(\.rule.name).sorted() == ["gt-to-ge", "lt-to-le"])
        // The third file is untouched: its mutant produces `e <= f`, which nothing refuses.
        let third = try #require(validated.files.last)
        #expect(third.instrumented.mutants.map(\.rule.name) == ["lt-to-le"])
    }
}
