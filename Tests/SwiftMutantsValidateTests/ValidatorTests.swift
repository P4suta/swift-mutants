// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import Testing

@testable import SwiftMutantsValidate

/// Finding out what the compiler will not accept, and doing it in as few compiles as
/// possible.
///
/// The loop is: instrument everything, ask once, drop what was refused, ask again. It
/// converges because every round that finds a rejection removes at least one candidate,
/// and it usually ends after two compiles - one that finds every rejection at once, and
/// one that confirms what is left.
///
/// When a compile complains about something it will not place, the loop stops guessing and
/// bisects. That is the expensive path and it is deliberately the second one: a compile per
/// halving, on a toolchain where a compile is the expensive thing.
@Suite("Validator")
struct ValidatorTests {

    /// A compiler that refuses whatever the test says it refuses.
    ///
    /// It reads the files that were actually written, so what it answers is a fact about
    /// the instrumented text rather than about a plan the test kept on the side. A driver
    /// that wrote the wrong bytes would be caught by this rather than agreed with.
    final class Stub: TypecheckDriver, @unchecked Sendable {

        /// Text that makes the compiler refuse the line holding it.
        let refusing: [String]

        /// Text that makes it refuse without saying where, as a compiler does when the
        /// error is in a macro buffer or a synthesised declaration.
        let refusingSilently: [String]

        /// Text that makes the compiler complain at a position nowhere near it - the
        /// shape of `missing return`, reported at a closing brace.
        let complainingAbout: [String]

        /// Which file that complaint names, when it is not the one the text is in.
        ///
        /// The compiler really can blame a file other than the one a mutant is in: a
        /// declaration whose inference fails takes its users with it.
        let blaming: String?

        private(set) var compiles = 0

        init(
            refusing: [String],
            refusingSilently: [String] = [],
            complainingAbout: [String] = [],
            blaming: String? = nil
        ) {
            self.refusing = refusing
            self.refusingSilently = refusingSilently
            self.complainingAbout = complainingAbout
            self.blaming = blaming
        }

        func typecheck(_ paths: [String]) async -> CompilerOutput {
            compiles += 1
            var said: [String] = []
            var failed = false
            for path in paths {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    continue
                }
                let bytes = Array(text.utf8)
                let index = LineIndex(text)
                for needle in refusing {
                    for start in Self.occurrences(of: needle, in: bytes) {
                        guard let place = index.position(of: start) else { continue }
                        said.append(
                            "\(path):\(place.line):\(place.column): error: refusing '\(needle)'")
                        failed = true
                    }
                }
                for needle in refusingSilently where text.contains(needle) {
                    said.append("<unknown>:0: error: something, somewhere")
                    failed = true
                }
                // At line one, which no guard reaches: the position says nothing and only
                // the file name does.
                for needle in complainingAbout where text.contains(needle) {
                    let named = blaming.map { Self.sibling(of: path, named: $0) } ?? path
                    said.append("\(named):1:1: error: missing return somewhere in here")
                    failed = true
                }
            }
            return CompilerOutput(exitCode: failed ? 1 : 0, text: said.joined(separator: "\n"))
        }

        static func sibling(of path: String, named name: String) -> String {
            path.split(separator: "/").dropLast().joined(separator: "/") + "/" + name
        }

        static func occurrences(of needle: String, in bytes: [UInt8]) -> [Int] {
            let pattern = Array(needle.utf8)
            guard !pattern.isEmpty, bytes.count >= pattern.count else { return [] }
            var found: [Int] = []
            for start in 0...(bytes.count - pattern.count)
            where Array(bytes[start..<(start + pattern.count)]) == pattern {
                found.append(start)
            }
            return found
        }
    }

    /// A directory to write instrumented files into, and the way to take it away again.
    struct Scratch {
        let directory: URL
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    static func scratch() throws -> Scratch {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-validate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Scratch(directory: directory)
    }

    static func subject(
        _ source: String, named name: String = "Subject.swift"
    )
        -> FileUnderValidation
    {
        guard let relative = WorkspaceRelativePath("Sources/\(name)") else {
            fatalError("malformed fixture path")
        }
        return FileUnderValidation(
            name: name,
            source: source,
            discovery: Discover.candidates(in: source, at: relative)
        )
    }

    @Test("accepts a tree the compiler accepts, in one compile")
    func acceptsAGoodTree() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: [])

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b }")])

        #expect(validated.rejected.isEmpty)
        #expect(validated.files.first?.instrumented.mutants.count == 1)
        #expect(compiler.compiles == 1)
    }

    /// The claim the design rests on: every rejection in one compile, and one more to
    /// confirm what is left. Not one compile per mutant, and not one per halving.
    @Test("finds every rejection in one compile and confirms in a second")
    func findsThemAllAtOnce() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: ["a <= b", "a >= b"])

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b && a > b }")])

        #expect(validated.rejected.map(\.rule.name).sorted() == ["gt-to-ge", "lt-to-le"])
        #expect(compiler.compiles == 2)
        #expect(validated.rounds == 2)
    }

    /// A rejection keeps the compiler's own sentence. It is the only moment that sentence
    /// exists: once the refused mutants are dropped the tree compiles and nothing says why
    /// one of them could not.
    @Test("keeps what the compiler said")
    func keepsTheWords() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: ["a <= b"])

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b }")])

        let rejection = try #require(validated.rejected.first)
        #expect(rejection.diagnostics.first?.message == "refusing 'a <= b'")
    }

    @Test("leaves the mutants the compiler accepted")
    func keepsTheRest() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: ["a <= b"])

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b && a > b }")])

        let kept = try #require(validated.files.first?.instrumented.mutants.map(\.rule.name))
        #expect(!kept.contains("lt-to-le"))
        #expect(kept.contains("gt-to-ge"))
        #expect(kept.contains("and-to-or"))
    }

    /// The survivors are renumbered densely, because the runtime compares against one
    /// integer and a gap would mean an index nothing answers to.
    @Test("renumbers what survives")
    func renumbers() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: ["a <= b"])

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b && a > b }")])

        let file = try #require(validated.files.first?.instrumented)
        #expect(file.mutants.map(\.index).sorted() == Array(0..<UInt32(file.mutants.count)))
    }

    /// A mutant's name comes from the file the user wrote, so dropping its neighbours must
    /// not rename it. Otherwise every cached outcome would be invalidated by an unrelated
    /// rejection somewhere else in the file.
    @Test("does not rename the survivors")
    func identitiesSurvive() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let source = "func f(_ a: Int, _ b: Int) -> Bool { a < b && a > b }"

        let before = try await Validator(compiler: Stub(refusing: []), directory: scratch.directory)
            .validate([Self.subject(source)])
        let after = try await Validator(
            compiler: Stub(refusing: ["a <= b"]), directory: scratch.directory
        ).validate([Self.subject(source)])

        let kept = Set(after.files.first?.instrumented.mutants.map(\.identity) ?? [])
        let all = Set(before.files.first?.instrumented.mutants.map(\.identity) ?? [])
        #expect(!kept.isEmpty)
        #expect(kept.isSubset(of: all))
    }

    /// A compiler that refuses without saying where explains nothing, and the loop must
    /// not invent an explanation. Bisection is what answers instead.
    @Test("bisects when a compile will not say what it is complaining about")
    func bisects() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: [], refusingSilently: ["a <= b"])

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b && a > b }")])

        #expect(validated.rejected.map(\.rule.name) == ["lt-to-le"])
        #expect(validated.bisected)
    }

    /// A compile that explained half of what it complained about explained nothing that
    /// can be acted on: the unplaced error might belong to a mutant the placed ones would
    /// let through. Taking the placeable half and moving on is how a tool ends up building
    /// a tree it was already told would not build.
    @Test("does not act on half an explanation")
    func partialAttribution() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: ["a <= b"], refusingSilently: ["a >= b"])

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b && a > b }")])

        #expect(validated.bisected)
        #expect(validated.rejected.map(\.rule.name).sorted() == ["gt-to-ge", "lt-to-le"])

        // The one the compiler placed keeps the sentence it was refused with. The one
        // halving found carries none, because there were none to carry - a rejection
        // reports what was said about it, never a sentence this tool composed.
        let placed = try #require(validated.rejected.first { $0.rule.name == "lt-to-le" })
        #expect(placed.diagnostics.map(\.message) == ["refusing 'a <= b'"])
        let halved = try #require(validated.rejected.first { $0.rule.name == "gt-to-ge" })
        #expect(halved.diagnostics.isEmpty)
    }

    /// Bisection costs a compile per halving rather than one per mutant, which is the only
    /// reason it is an acceptable fallback at all.
    @Test("bisects in compiles proportional to the logarithm of the catalogue")
    func bisectionCost() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        // Distinct operands throughout, so that the text a mutant produces appears in the
        // file only when that mutant is in it. A needle the original source already holds
        // would make every subset fail, including the empty one.
        let source = """
            func f(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Bool {
                let one = a < b
                let two = c > d
                let three = a == c
                let four = b != d
                let five = a <= c
                let six = b >= d
                return one && two && three && four && five && six
            }
            """
        // Refused at both ends of the catalogue, so a search that walked it one at a time
        // would have to walk all of it. Halving reaches either end in the same few steps.
        let compiler = Stub(refusing: [], refusingSilently: ["a <= b", "five || six"])
        let subject = Self.subject(source)
        let total = subject.discovery.candidates.count
        #expect(total >= 16)

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([subject])

        #expect(validated.rejected.count == 2)
        // Halving two targets out of n costs about 4*log2(n) compiles; walking the list
        // costs about 2n. The bound sits between the two and is checked rather than
        // assumed, because a fallback nobody measured is a fallback nobody bounded.
        let bound = 4 * Int(log2(Double(total)).rounded(.up)) + 4
        #expect(
            compiler.compiles <= bound,
            "bisection cost \(compiler.compiles) compiles over \(total) candidates"
        )
    }

    /// If nothing is left to blame, the file itself does not compile. Saying a mutant did
    /// it would blame the tool's own work for the state of somebody's package.
    @Test("says the package does not compile rather than blaming a mutant")
    func originalBroken() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: [], refusingSilently: ["func f"])

        let failure = await #expect(throws: ValidationError.self) {
            try await Validator(compiler: compiler, directory: scratch.directory)
                .validate([Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b }")])
        }
        #expect(failure?.reason.contains("no mutants in it at all") == true)
    }

    @Test("validates several files together")
    func severalFiles() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let compiler = Stub(refusing: ["a <= b"])

        let validated = try await Validator(compiler: compiler, directory: scratch.directory)
            .validate([
                Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b }", named: "One.swift"),
                Self.subject("func g(_ a: Int, _ b: Int) -> Bool { a > b }", named: "Two.swift"),
            ])

        #expect(validated.files.count == 2)
        #expect(validated.rejected.map(\.rule.name) == ["lt-to-le"])
        #expect(compiler.compiles == 2)
    }

    /// The tool writes into its own directory and nowhere else.
    @Test("writes only into the directory it was given")
    func writesWhereItWasTold() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }

        _ = try await Validator(compiler: Stub(refusing: []), directory: scratch.directory)
            .validate([Self.subject("func f(_ a: Int, _ b: Int) -> Bool { a < b }")])

        let written = try FileManager.default.contentsOfDirectory(atPath: scratch.directory.path)
        #expect(written == ["Subject.swift"])
    }
}
