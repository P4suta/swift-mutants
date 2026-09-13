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
            .compactMap { Self.parseLine(String($0)) }
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
