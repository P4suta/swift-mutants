// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsValidate

/// Reading what the compiler said.
///
/// A rejection is a fact about the program, not a decision this tool made, so it is
/// reported in the compiler's own words. That means keeping those words - and the place
/// they point at, which is what says *which* mutant the compiler is talking about.
@Suite("Compiler diagnostics")
struct DiagnosticTests {

    @Test("reads a diagnostic line")
    func readsOne() throws {
        let found = CompilerDiagnostic.parse(
            "reject.swift:4:70: error: binary operator '-' cannot be applied to two 'String' operands"
        )
        let diagnostic = try #require(found.first)
        #expect(diagnostic.file == "reject.swift")
        #expect(diagnostic.position == SourcePosition(line: 4, column: 70))
        #expect(diagnostic.severity == .error)
        #expect(
            diagnostic.message
                == "binary operator '-' cannot be applied to two 'String' operands"
        )
    }

    /// The compiler's words arrive dressed for a terminal, and the dress is not the words.
    ///
    /// SwiftPM's build system colours diagnostics and wraps each diagnostic group name in
    /// an OSC-8 hyperlink, whether or not anything is attached to a terminal. A parser
    /// looking for a literal ": error: " then matches nothing at all - and matching
    /// nothing is not a parse failure anybody sees. It is a compile that "refused no
    /// mutant this tool could place", which sends validation into the bisection fallback:
    /// one compile per halving instead of one compile in total. Measured on this
    /// repository the day Swift 6.4 arrived: 1097 mutants, no attribution, and a halving
    /// that had not finished after twenty minutes.
    @Test("reads a diagnostic a terminal was meant to read")
    func readsThroughTheColour() throws {
        // Byte for byte what `swift build` writes into a pipe: CSI colour runs, and an
        // OSC-8 hyperlink around the diagnostic group name at the end.
        let escape = "\u{1B}"
        let coloured =
            "/tmp/tree/Sources/Core/Core.swift:104:33: \(escape)[1;31merror: \(escape)[1;39m"
            + "no unsafe operations occur within 'unsafe' expression\(escape)[0;0m "
            + "[#\(escape)]8;;https://docs.swift.org/x\(escape)\\UnnecessaryUnsafe"
            + "\(escape)]8;;\(escape)\\]"

        let diagnostic = try #require(CompilerDiagnostic.parse(coloured).first)
        #expect(diagnostic.file == "/tmp/tree/Sources/Core/Core.swift")
        #expect(diagnostic.position == SourcePosition(line: 104, column: 33))
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.hasPrefix("no unsafe operations occur"))
        // Nothing of the dressing survives into what a reader is shown.
        #expect(!diagnostic.message.contains(escape))
    }

    /// The whole point of one typecheck rather than a bisection: swiftc keeps going after
    /// the first error and reports every one of them.
    @Test("reads every diagnostic in one compile")
    func readsAllOfThem() {
        let found = CompilerDiagnostic.parse(
            """
            reject.swift:4:70: error: binary operator '-' cannot be applied to two 'String' operands
            let bad = a - b
                      ~ ^ ~
            reject.swift:6:67: error: binary operator '/' cannot be applied to two '[Int]' operands
            """
        )
        #expect(found.count == 2)
        #expect(found.map(\.position.line) == [4, 6])
    }

    /// Source excerpts and caret lines sit between the diagnostics. Taking one of those
    /// for a diagnostic would invent a position and reject whatever mutant sat there.
    @Test("ignores the source excerpt around a diagnostic")
    func ignoresExcerpts() {
        let found = CompilerDiagnostic.parse(
            """
            a.swift:1:5: error: no
            let x: Int = "s"
                         ^~~
            """
        )
        #expect(found.count == 1)
    }

    @Test("keeps warnings and notes apart from errors")
    func severities() {
        let found = CompilerDiagnostic.parse(
            """
            a.swift:1:1: warning: unused
            a.swift:2:1: note: declared here
            a.swift:3:1: error: no
            """
        )
        #expect(found.map(\.severity) == [.warning, .note, .error])
    }

    /// A path with a colon in it is legal on every platform this runs on, and the line
    /// and column are the last two colon-separated numbers rather than the first.
    @Test("reads a path that has colons in it")
    func pathsWithColons() throws {
        let found = CompilerDiagnostic.parse("/tmp/a:b/S.swift:12:3: error: no")
        let diagnostic = try #require(found.first)
        #expect(diagnostic.file == "/tmp/a:b/S.swift")
        #expect(diagnostic.position == SourcePosition(line: 12, column: 3))
    }

    /// Something that is not a diagnostic must not become one. A compiler that changed
    /// its output format should make this tool fall back to bisection, not make it reject
    /// mutants at positions it invented.
    @Test(
        "reads nothing out of what is not a diagnostic",
        arguments: [
            "",
            "hello",
            "a.swift:1: error: no",
            "a.swift:x:1: error: no",
            "a.swift:1:1: shouting: no",
            "a.swift:1:0: error: no",
            "a.swift:0:1: error: no",
            "a.swift:-1:1: error: no",
            "a.swift:1:1: error:",
            ":1:1: error: no",
        ])
    func refusesNonDiagnostics(line: String) {
        #expect(CompilerDiagnostic.parse(line).isEmpty, "parsed: \(line)")
    }

    /// `error:` appearing inside a message is not a second diagnostic.
    @Test("does not find a diagnostic inside a message")
    func noNestedDiagnostics() {
        let found = CompilerDiagnostic.parse(
            "a.swift:1:1: error: cannot find 'b.swift:2:2: error: x' in scope"
        )
        #expect(found.count == 1)
        #expect(found.first?.message == "cannot find 'b.swift:2:2: error: x' in scope")
    }
}

/// What a failure says to the person reading it.
///
/// "It did not compile" without the sentence saying why is the least useful thing a tool
/// can produce, and this is the string that reaches a terminal.
@Suite("Validation errors")
struct ValidationErrorTests {

    static func diagnostic(
        _ severity: CompilerDiagnostic.Severity, _ message: String
    )
        -> CompilerDiagnostic
    {
        CompilerDiagnostic(
            file: "S.swift",
            position: SourcePosition(line: 1, column: 1),
            severity: severity,
            message: message
        )
    }

    /// A failed build reports hundreds of diagnostics, and the first few are usually
    /// warnings from somewhere unrelated. A reader given those is looking in the wrong file.
    @Test("shows the errors, not the warnings that came first")
    func errorsBeforeWarnings() {
        let error = ValidationError(
            "it did not build",
            diagnostics: [
                Self.diagnostic(.warning, "unrelated"),
                Self.diagnostic(.warning, "also unrelated"),
                Self.diagnostic(.error, "this is the one"),
            ]
        )
        #expect(error.description.contains("this is the one"))
        #expect(!error.description.contains("unrelated"))
    }

    /// A build can fail with no error of its own - a linker, a plugin, a toolchain that
    /// exited oddly - and saying nothing then would be worse than saying what there was.
    @Test("falls back to whatever there was when there are no errors")
    func warningsWhenThatIsAll() {
        let error = ValidationError(
            "it did not build",
            diagnostics: [Self.diagnostic(.warning, "only this")]
        )
        #expect(error.description.contains("only this"))
    }

    @Test("says how many more it is not showing")
    func boundsWhatItPrints() {
        let error = ValidationError(
            "it did not build",
            diagnostics: (1...9).map { Self.diagnostic(.error, "problem \($0)") }
        )
        #expect(error.description.contains("problem 1"))
        #expect(!error.description.contains("problem 9"))
        #expect(error.description.contains("and 4 more"))
    }

    @Test("says only the reason when the compiler said nothing")
    func noDiagnostics() {
        #expect(ValidationError("it did not build").description == "it did not build")
    }
}
