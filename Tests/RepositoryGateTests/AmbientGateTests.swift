// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Keeps the ambient environment to one doorway.
///
/// The engine is given an environment; it never goes and gets one. That is what makes a
/// scripted toolchain able to stand in for a real one, and it is what lets a trace record
/// the environment a child process actually received. The rule survives only if there is
/// exactly one place the real environment enters, so this counts the places.
///
/// `ast-grep`'s `no-process-info-environment` says the same thing syntactically. Two
/// gates, because the failure they prevent - a second reach added in an afternoon, in a
/// file nobody thought of as a boundary - is silent in both tests and review.
@Suite("Ambient gate")
struct AmbientGateTests {

    /// The one file allowed to read the process's own environment.
    static let doorway = "Sources/SwiftMutantsCLI/Ambient.swift"

    /// Test support supplies an environment rather than reaching for one, except the
    /// scripted toolchain, which *is* a process being told what to do and can only be
    /// told through its own environment.
    static let exempt = ["Sources/swift-mutants-fake-toolchain"]

    @Test("only one file reads the process's own environment")
    func oneDoorway() throws {
        var reaches: [String] = []
        for file in try RepositoryGate.swiftFiles(under: "Sources") {
            let path = RepositoryGate.repositoryRelativePath(file)
            guard path != Self.doorway else { continue }
            guard !Self.exempt.contains(where: { path.hasPrefix($0) }) else { continue }
            let code = Self.outsideStringLiterals(try RepositoryGate.codeLines(of: file))
            for name in ["ProcessInfo.processInfo.environment", "getenv("]
            where code.contains(name) {
                reaches.append("\(path): \(name)")
            }
        }
        #expect(
            reaches.isEmpty,
            """
            These reach for the ambient environment directly. Take an environment as a \
            parameter instead, or route the read through \(Self.doorway):
            \(reaches.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Drops every string literal, keeping the code around them.
    ///
    /// `SwiftMutantsInstrument` has `getenv` in its source because the runtime it *writes*
    /// calls `getenv` - that text runs in the package under test, a process this one does
    /// not own, and reading it once into a lazily-initialised global is exactly what the
    /// runtime is for. Exempting the file by name would leave a hole the shape of a file;
    /// exempting quoted text leaves a hole the shape of quoted text, which is the truth.
    static func outsideStringLiterals(_ source: String) -> String {
        var kept = ""
        var rest = Substring(source)
        while let opening = rest.firstRange(of: "\"") {
            kept += rest[rest.startIndex..<opening.lowerBound]
            let afterOpening = rest[opening.upperBound...]
            let isMultiline = afterOpening.hasPrefix("\"\"")
            let delimiter = isMultiline ? "\"\"\"" : "\""
            let body = isMultiline ? afterOpening.dropFirst(2) : afterOpening
            guard let closing = Self.closingQuote(of: delimiter, in: body) else { return kept }
            rest = body[closing...]
        }
        return kept + rest
    }

    /// Finds the delimiter that ends a literal, stepping over backslash escapes.
    static func closingQuote(of delimiter: String, in body: Substring) -> Substring.Index? {
        var index = body.startIndex
        while index < body.endIndex {
            if body[index] == "\\" {
                index = body.index(index, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex
                continue
            }
            if body[index...].hasPrefix(delimiter) {
                return body.index(index, offsetBy: delimiter.count)
            }
            index = body.index(after: index)
        }
        return nil
    }

    /// A doorway that stopped being a doorway would let the gate above pass by being
    /// vacuous, which is the failure mode of every allowlist.
    @Test("the doorway is still a doorway")
    func doorwayStillReads() throws {
        let source = try RepositoryGate.contents(
            of: RepositoryGate.root.appending(path: Self.doorway)
        )
        #expect(source.contains("ProcessInfo.processInfo.environment"))
    }
}
