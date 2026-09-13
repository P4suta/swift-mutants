// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsValidate

/// The claim put to the real compiler.
///
/// Everything else about validation is a statement about text and about a stub that agreed
/// with it. This asks `swiftc` the three questions text cannot answer: does it report every
/// error rather than stopping at the first, does `line:col` land inside the branch that
/// broke, and does the whole loop therefore settle in two compiles.
///
/// A tool that got this wrong would either reject mutants that compile - losing coverage
/// silently - or keep mutants that do not, and fail the build later with no idea why.
@Suite("Validation, against the real compiler")
struct ValidateIntegrationTests {

    /// Two types that have one operator each and are not `Equatable` or `Comparable`.
    ///
    /// So `==` exists and `!=` does not, and `<` exists and `<=` does not. That makes the
    /// comparison rules produce expressions the compiler genuinely refuses, which is the
    /// only way to find out what it says about them.
    static let subject = """
        struct Tag {
            let name: String
            static func == (lhs: Tag, rhs: Tag) -> Bool { lhs.name == rhs.name }
        }

        struct Rank {
            let value: Int
            static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.value < rhs.value }
        }

        func sameTag(_ a: Tag, _ b: Tag) -> Bool {
            return a == b
        }

        func lower(_ a: Rank, _ b: Rank) -> Bool {
            return a < b
        }

        func bothOf(_ a: Bool, _ b: Bool) -> Bool {
            return a && b
        }
        """

    struct Scratch {
        let directory: URL
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    static func scratch() throws -> Scratch {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-validate-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Scratch(directory: directory)
    }

    static func validator(in directory: URL) -> Validator {
        Validator(
            compiler: SwiftcDriver(
                runner: Runner(recorder: TraceRecorder()),
                executable: "/usr/bin/swiftc",
                extraArguments: ["-swift-version", "6"],
                directory: directory.path
            ),
            directory: directory
        )
    }

    static func subjectFile(_ source: String = Self.subject) -> FileUnderValidation {
        guard let relative = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return FileUnderValidation(
            name: "Subject.swift",
            source: source,
            discovery: Discover.candidates(in: source, at: relative)
        )
    }

    /// The whole claim in one test: the compiler refuses two mutants, says so about both
    /// in a single compile, and the loop settles in two.
    @Test("finds every rejection the compiler has, in two compiles", .tags(.integration))
    func findsRejections() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }

        let validated = try await Self.validator(in: scratch.directory)
            .validate([Self.subjectFile()])

        #expect(validated.rejected.map(\.rule.name).sorted() == ["eq-to-neq", "lt-to-le"])
        #expect(!validated.bisected, "the compiler explained itself; halving was not needed")
        #expect(validated.rounds == 2)
    }

    /// The rejection carries the compiler's own sentence, which is the only moment that
    /// sentence exists: once the refused mutants are gone the tree compiles and nothing
    /// says why one of them could not.
    @Test("keeps the compiler's own words", .tags(.integration))
    func keepsTheWords() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }

        let validated = try await Self.validator(in: scratch.directory)
            .validate([Self.subjectFile()])

        let rejection = try #require(validated.rejected.first { $0.rule.name == "eq-to-neq" })
        let said = try #require(rejection.diagnostics.first?.message)
        #expect(said.contains("!="), "the compiler's sentence was lost: \(said)")
    }

    /// What survives has to be a program. This is the gate that catches an instrumenter
    /// that produced text nobody can compile.
    @Test("leaves behind a tree the compiler accepts", .tags(.integration))
    func survivorsCompile() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }

        let validated = try await Self.validator(in: scratch.directory)
            .validate([Self.subjectFile()])

        let kept = try #require(validated.files.first?.instrumented.mutants)
        // By identity, not by rule name: `eq-to-neq` is refused where the operands are
        // `Tag` and perfectly fine inside `Tag.==` itself, where they are `String`. A tool
        // that dropped a rule wherever one use of it failed would lose real coverage.
        #expect(Set(kept.map(\.identity)).isDisjoint(with: validated.rejected.map(\.identity)))
        #expect(kept.map(\.rule.name).contains("and-to-or"))
        #expect(kept.count == 5)

        // The written file is the one the compiler last accepted.
        let written = try String(
            contentsOfFile: try #require(validated.files.first?.path), encoding: .utf8)
        #expect(!written.contains("a != b"))
        #expect(!written.contains("a <= b"))
        #expect(written.contains("a || b"))
    }

    /// Line numbers are the contract with every coverage profile taken later. The guards
    /// are expressions and the runtime is appended, so nothing above it moves.
    @Test("does not move a single line", .tags(.integration))
    func linesAreStable() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }

        let validated = try await Self.validator(in: scratch.directory)
            .validate([Self.subjectFile()])

        let file = try #require(validated.files.first?.instrumented)
        let original = Self.subject.split(separator: "\n", omittingEmptySubsequences: false).count
        let produced = file.source.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(produced - file.runtimeLineCount == original)
    }

    /// A file that does not compile on its own is not a mutant's fault, and saying it was
    /// would blame this tool's work for the state of somebody's package.
    @Test("refuses to blame a mutant for a file that never compiled", .tags(.integration))
    func brokenOriginal() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let broken = """
            func f(_ a: Int, _ b: Int) -> Bool {
                return a < b
            }
            let x: Int = "not an integer"
            """

        let failure = await #expect(throws: ValidationError.self) {
            try await Self.validator(in: scratch.directory).validate([Self.subjectFile(broken)])
        }
        #expect(failure?.reason.contains("does not compile") == true)
        // The compiler's own sentence reaches the person reading the error, not only the
        // fact that there was one. "It did not compile" without the why is the least
        // useful thing a tool can say.
        #expect(failure?.description.contains("error:") == true, "\(failure as Any)")
    }

    /// Nothing to do is a valid answer, and it costs one compile.
    @Test("accepts a file with no rejections at all", .tags(.integration))
    func nothingRejected() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }
        let clean = """
            func f(_ a: Int, _ b: Int) -> Bool {
                return a < b && a > b
            }
            """

        let validated = try await Self.validator(in: scratch.directory)
            .validate([Self.subjectFile(clean)])

        #expect(validated.rejected.isEmpty)
        #expect(validated.rounds == 1)
        #expect(validated.files.first?.instrumented.mutants.count == 5)
    }
}

extension Tag {
    /// Needs a real Swift toolchain.
    @Tag static var integration: Self
}
