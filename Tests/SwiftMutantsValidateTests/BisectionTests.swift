// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import Synchronization
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

    /// A build stops at the first module that fails, so removing one layer's refusals is
    /// what lets the next layer's errors appear at all. Halving is therefore another way
    /// to remove candidates, not another way to finish: treating it as an ending made a
    /// run give up on the layer it had just uncovered.
    ///
    /// Found by running swift-mutants on swift-mutants, where the layers were real
    /// modules and each round revealed the next.
    @Test("keeps going after halving, because a build reveals one layer at a time")
    func layersAppearOneAtATime() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        // The first is unplaceable and forces halving; the second only becomes visible
        // once the first is gone, the way a module's errors wait for its dependency's.
        let compiler = Layered(
            first: "a >= b", then: "c <= d", failingSilentlyOn: "a >= b")

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([
                Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a > b }", named: "One.swift"),
                Self.subject("func g(_ c: Int, _ d: Int) -> Bool { c < d }", named: "Two.swift"),
            ])

        #expect(validated.bisected)
        #expect(validated.rejected.map(\.rule.name).sorted() == ["gt-to-ge", "lt-to-le"])
    }

    /// A compiler that hides the second problem until the first is gone.
    final class Layered: TypecheckDriver, @unchecked Sendable {

        private let first: String
        private let then: String
        private let silent: String

        init(first: String, then: String, failingSilentlyOn silent: String) {
            self.first = first
            self.then = then
            self.silent = silent
        }

        func typecheck(_ paths: [String]) async -> CompilerOutput {
            let texts = paths.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            let joined = texts.joined()
            if joined.contains(first) {
                return CompilerOutput(
                    exitCode: 1,
                    text: silent == first
                        ? "<unknown>:0: error: something, somewhere"
                        : "\(paths[0]):1:1: error: no"
                )
            }
            guard joined.contains(then) else { return CompilerOutput(exitCode: 0, text: "") }
            // Placeable, so the loop can name it without halving again.
            guard
                let path = paths.first(where: {
                    (try? String(contentsOfFile: $0, encoding: .utf8))?.contains(then) == true
                }),
                let text = try? String(contentsOfFile: path, encoding: .utf8),
                let offset = Self.offset(of: then, in: text),
                let place = LineIndex(text).position(of: offset)
            else { return CompilerOutput(exitCode: 1, text: "<unknown>:0: error: lost") }
            return CompilerOutput(
                exitCode: 1, text: "\(path):\(place.line):\(place.column): error: no")
        }

        static func offset(of needle: String, in text: String) -> Int? {
            let bytes = Array(text.utf8)
            let pattern = Array(needle.utf8)
            guard bytes.count >= pattern.count else { return nil }
            for start in 0...(bytes.count - pattern.count)
            where Array(bytes[start..<(start + pattern.count)]) == pattern {
                return start
            }
            return nil
        }
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

/// What a bisection says while it runs.
///
/// The halving is the one phase that can run for a long time saying nothing. Reported by
/// somebody whose run printed `halving 802 mutants` and then nothing at all for forty
/// minutes before exiting: from outside, a bisection working and a bisection that has died
/// are the same silence, and the count that would have told them apart was being kept and
/// never shown.
@Suite("A bisection saying what it is doing")
struct BisectionProgressTests {

    @Test("says something for every compile it spends")
    func speaksEveryCompile() async throws {
        let scratch = try BisectionTests.scratch()
        defer { scratch.cleanUp() }
        // Refused, and unplaceable, so the loop has no choice but to halve.
        let compiler = BisectionTests.Stub(refusing: [], refusingSilently: ["a >= b"])

        let said = Mutex<[Validator.Progress]>([])
        _ = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate(
                [
                    BisectionTests.subject(
                        "func f(_ a: Int, _ b: Int) -> Bool { a < b }", named: "One.swift"),
                    BisectionTests.subject(
                        "func g(_ a: Int, _ b: Int) -> Bool { a > b }", named: "Two.swift"),
                ]
            ) { step in said.withLock { $0.append(step) } }

        let halvings = said.withLock { $0 }.compactMap { step -> Int? in
            guard case .halved(let compiles, _, _) = step else { return nil }
            return compiles
        }
        #expect(!halvings.isEmpty, "the halving said nothing at all")
        // A count that only goes up, so a reader watching it can tell progress from a hang.
        #expect(halvings == halvings.sorted())
    }
}
