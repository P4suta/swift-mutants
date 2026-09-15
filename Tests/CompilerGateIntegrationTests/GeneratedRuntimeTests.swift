// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import SwiftMutantsTestKit
import Testing

/// The runtime this tool writes into somebody else's package, put to the real compiler.
///
/// Generated code has no business producing a warning. Every instrumented file carries
/// this runtime, so one warning becomes one per file - and in a package that turns
/// warnings into errors, which this one does and which is ordinary practice, it is not a
/// warning at all but a build that does not happen. The tool would then report "the
/// instrumented copy could not be built" about code the user never wrote.
///
/// It is written down as a compile rather than as a string comparison because that is the
/// only form of the question the compiler answers. `InstrumentTests` asserts that the
/// runtime spells the unsafe calls both ways; that assertion stayed true, and green, while
/// Swift 6.4 turned one of the two spellings into a diagnostic. A test that reads the
/// generated text can only check the shape somebody expected, and the whole risk here is
/// the shape nobody expected.
///
/// Both configurations, because the runtime has two branches and a package compiles
/// exactly one of them. A gate that checked the branch this repository uses would leave
/// the other free to rot, and the other is the one most packages take.
@Suite("The generated runtime, as the compiler sees it")
struct GeneratedRuntimeTests {

    /// A file with something to mutate, so a runtime is generated at all.
    static func runtime() throws -> String {
        guard let path = WorkspaceRelativePath("Sources/Subject/Subject.swift") else {
            throw ToolchainGate.Failure("malformed fixture path")
        }
        let source = """
            func compare(_ a: Int, _ b: Int) -> Bool { a < b }
            func combine(_ a: Bool, _ b: Bool) -> Bool { a && b }
            """
        let discovery = Discover.candidates(in: source, at: path)
        return try Instrument.file(source, discovery: discovery).source
    }

    /// A right-aligned line number, so the quoted source reads like the compiler's own.
    static func numbering(_ line: Int) -> String {
        let digits = "\(line)"
        return String(repeating: " ", count: max(0, 4 - digits.count)) + digits + "  "
    }

    /// Compiles the generated source, and fails with whatever the compiler said.
    ///
    /// `-warnings-as-errors` is the point rather than a precaution: it is what turns the
    /// question "does this warn" into one a process exit code can answer.
    static func typecheck(_ source: String, strictMemorySafety: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "Instrumented.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)

        var arguments = ["-typecheck", "-swift-version", "6", "-warnings-as-errors"]
        if strictMemorySafety { arguments.append("-strict-memory-safety") }
        do {
            _ = try ToolchainGate.run("swiftc", arguments + [file.path])
        } catch {
            // With the generated source, numbered. The compiler points at a line of a file
            // nobody wrote and which this test deletes on the way out, so a failure that
            // quoted only the diagnostic would be a failure nobody could read.
            let numbered = source.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .map { Self.numbering($0.offset + 1) + $0.element }
                .joined(separator: "\n")
            throw ToolchainGate.Failure(
                """
                \(error)

                The generated source it refused:
                \(numbered)
                """
            )
        }
    }

    @Test("compiles without a warning under -strict-memory-safety")
    func strictMemorySafety() throws {
        try Self.typecheck(try Self.runtime(), strictMemorySafety: true)
    }

    @Test("compiles without a warning without it")
    func withoutStrictMemorySafety() throws {
        try Self.typecheck(try Self.runtime(), strictMemorySafety: false)
    }
}
