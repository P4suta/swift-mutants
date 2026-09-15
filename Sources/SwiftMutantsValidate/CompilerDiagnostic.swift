// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// One thing the compiler said about one place in a file.
///
/// A rejection is a fact about the program rather than a decision this tool made, so it
/// travels in the compiler's own words. The words are for the reader; the position is for
/// attribution, which is what decides *which* mutant the compiler was talking about.
public struct CompilerDiagnostic: Sendable, Hashable {

    /// How seriously the compiler meant it.
    public enum Severity: String, Sendable, Hashable, CaseIterable {
        case error
        case warning
        case note
    }

    /// The file the compiler named, exactly as it named it.
    public let file: String

    /// Where in that file, counting columns in UTF-8 bytes as the compiler does.
    public let position: SourcePosition

    /// How seriously the compiler meant it.
    public let severity: Severity

    /// What it said, with the severity and position stripped off the front.
    public let message: String

    /// Whether the compiler ran out of budget rather than finding anything wrong.
    ///
    /// A different thing from a refusal, and a different thing for somebody to do about.
    /// A refused mutant is a fact about the mutant and there is nothing to act on - the
    /// tool drops it and moves on. An expression the compiler cannot afford to type-check
    /// is a fact about *their* code: it type-checks fine as written and tips over once
    /// guards wrap its subexpressions, which means it was already close to the edge.
    /// Breaking it into statements is usually an improvement they wanted anyway.
    ///
    /// It also costs differently, which decides how a run behaves. Looking for an invalid
    /// mutant, every compile fails fast; looking for an unaffordable one, every compile
    /// pays the whole type-checking budget first. Reported from a real package: seven and
    /// a half minutes of halving on a package that builds in forty.
    ///
    /// Only an error. A warning saying the same thing did not stop a build, so it is not
    /// why a compile failed.
    public var isUnaffordable: Bool {
        severity == .error && message.contains("type-check this expression in reasonable time")
    }

    /// Creates a diagnostic.
    public init(file: String, position: SourcePosition, severity: Severity, message: String) {
        self.file = file
        self.position = position
        self.severity = severity
        self.message = message
    }
}

extension CompilerDiagnostic {

    /// Reads every diagnostic out of what a compiler wrote.
    ///
    /// One typecheck is enough because `swiftc` does not stop at the first error: it
    /// reports all of them, each pointing at the operator that broke. So a single compile
    /// of a fully instrumented file names every mutant the compiler refuses, and bisection
    /// stays a fallback for the cases where that fails rather than being the mechanism.
    ///
    /// Line-oriented and strict. Between diagnostics the compiler prints the source line
    /// and a caret, and neither is a diagnostic; a parser that guessed would invent a
    /// position and reject whatever mutant happened to sit at it. Anything that is not
    /// exactly `path:line:column: severity: message` is not read, which is also what makes
    /// a compiler that changes its output fall back to bisection rather than start
    /// rejecting mutants at positions nobody reported.
    public static func parse(_ output: String) -> [CompilerDiagnostic] {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { Self.parseLine(Self.undressed(String($0))) }
    }

    /// The same line with the terminal control sequences taken out of it.
    ///
    /// SwiftPM's build system colours diagnostics and wraps each diagnostic group name in
    /// an OSC-8 hyperlink whether or not anything is attached to a terminal, so a line
    /// arrives as `path:4:70: ESC[1;31merror: ESC[1;39mmessage`. The strictness above then
    /// reads it as not a diagnostic - and *that* is the dangerous part, because a line
    /// nobody could parse is indistinguishable from a compile that refused nothing. The
    /// run does not fail; it falls into the bisection fallback and pays a compile per
    /// halving instead of one compile in total.
    ///
    /// Stripped rather than suppressed with a flag, because the colouring is added by
    /// whatever ran the compiler rather than asked for by this tool, and a parser that
    /// only worked when it had talked the other program out of formatting would break
    /// again the next time something else was in the middle.
    ///
    /// Two shapes, which is all a compiler emits: `ESC[` ... a letter, and `ESC]` ... a
    /// bell or `ESC\`. Anything else is left exactly as it was: this removes decoration
    /// and must never remove a byte of the message.
    static func undressed(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        var plain = ""
        var rest = Substring(line)
        while let escape = rest.firstIndex(of: "\u{1B}") {
            plain += rest[rest.startIndex..<escape]
            guard let end = Self.endOfSequence(rest, at: escape) else {
                // Not a sequence this understands. Keep the escape and carry on from the
                // character after it, rather than guessing how much belonged to it.
                plain.append("\u{1B}")
                rest = rest[rest.index(after: escape)...]
                continue
            }
            rest = rest[end...]
        }
        return plain + rest
    }

    /// Where the escape sequence starting at `escape` ends, or nothing if it is not one.
    private static func endOfSequence(
        _ text: Substring, at escape: Substring.Index
    ) -> Substring.Index? {
        var index = text.index(after: escape)
        guard index < text.endIndex else { return nil }
        let introducer = text[index]
        index = text.index(after: index)
        switch introducer {
        case "[": return Self.endOfControl(text, from: index)
        case "]": return Self.endOfString(text, from: index)
        default: return nil
        }
    }

    /// The end of a CSI run: parameter and intermediate bytes, then one final byte.
    private static func endOfControl(
        _ text: Substring, from start: Substring.Index
    ) -> Substring.Index {
        var index = start
        while index < text.endIndex, !("@"..."~").contains(text[index]) {
            index = text.index(after: index)
        }
        return index < text.endIndex ? text.index(after: index) : index
    }

    /// The end of an OSC string, which a bell or `ESC\` closes.
    ///
    /// The text it wraps is part of the message and is kept; only the two envelopes go.
    private static func endOfString(
        _ text: Substring, from start: Substring.Index
    ) -> Substring.Index {
        var index = start
        while index < text.endIndex {
            if text[index] == "\u{7}" { return text.index(after: index) }
            let next = text.index(after: index)
            if text[index] == "\u{1B}", next < text.endIndex, text[next] == "\\" {
                return text.index(after: next)
            }
            index = next
        }
        return index
    }

    private static func parseLine(_ line: String) -> CompilerDiagnostic? {
        // `severity: message` first, because a path may hold colons and a message
        // certainly may. Only the head before the first severity marker is a position.
        for severity in Severity.allCases {
            guard let marker = line.firstRange(of: ": \(severity.rawValue): ") else { continue }
            guard
                let place = Self.parsePlace(String(line[line.startIndex..<marker.lowerBound]))
            else { continue }
            let message = String(line[marker.upperBound...])
            guard !message.isEmpty else { return nil }
            return CompilerDiagnostic(
                file: place.file,
                position: place.position,
                severity: severity,
                message: message
            )
        }
        return nil
    }

    /// Splits `path:line:column`, taking the numbers off the end.
    ///
    /// From the end because a path may hold a colon and a line number may not.
    private static func parsePlace(_ head: String) -> (file: String, position: SourcePosition)? {
        let parts = head.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        guard
            let column = Int(parts[parts.count - 1]), column >= 1,
            let line = Int(parts[parts.count - 2]), line >= 1
        else { return nil }
        let file = parts[0..<(parts.count - 2)].joined(separator: ":")
        guard !file.isEmpty else { return nil }
        return (file, SourcePosition(line: line, column: column))
    }
}
