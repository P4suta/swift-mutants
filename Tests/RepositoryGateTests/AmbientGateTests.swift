// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Routes ambient environment access through the library adapter.
@Suite("Ambient gate")
struct AmbientGateTests {

    /// The one file allowed to read the process's own environment.
    static let doorway = "Sources/SwiftMutants/Ambient.swift"

    @Test("only one file reads the process's own environment")
    func oneDoorway() throws {
        var reaches: [String] = []
        for file in try RepositoryGate.swiftFiles(under: "Sources") {
            let path = RepositoryGate.repositoryRelativePath(file)
            guard path != Self.doorway else { continue }
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

    /// Ignores source literals used to generate the measured package's runtime.
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

    /// A doorway that stopped being a doorway would let the gate above pass by being vacuous, which is the failure mode of every allowlist.
    @Test("the doorway is still a doorway")
    func doorwayStillReads() throws {
        let source = try RepositoryGate.contents(
            of: RepositoryGate.root.appending(path: Self.doorway)
        )
        #expect(source.contains("ProcessInfo.processInfo.environment"))
    }
}
