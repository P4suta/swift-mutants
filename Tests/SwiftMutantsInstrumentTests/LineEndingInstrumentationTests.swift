// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover
import Testing

@testable import SwiftMutantsInstrument

@Suite("Instrumented source line endings")
struct LineEndingInstrumentationTests {
    @Test("flattened alternatives preserve original line endings", arguments: ["\n", "\r", "\r\n"])
    func flattenedAlternatives(ending: String) throws {
        let source = [
            "func predicate(_ a: Int, _ b: Int) -> Bool {",
            "    a < b && // compare the operands",
            "        a != 0",
            "}",
        ].joined(separator: ending)
        let file = try Self.instrument(source)
        try #require(!file.mutants.isEmpty)
        let bytes = Array(file.source.utf8)
        let body = bytes.dropLast(file.runtime.utf8.count)
        #expect(body.filter { $0 == 10 || $0 == 13 } == source.utf8.filter { $0 == 10 || $0 == 13 })
        for mutant in file.mutants {
            let copy = bytes[mutant.instrumentedSpan.start..<mutant.instrumentedSpan.end]
            #expect(!copy.contains(10) && !copy.contains(13))
        }
    }

    @Test("flattening retains Unicode separators inside single-line literals")
    func literalSeparators() throws {
        let source = "func same() -> Bool { \"a\u{2028}b\" == \"a\u{2028}b\" }"
        let file = try Self.instrument(source)
        try #require(!file.mutants.isEmpty)
        let bytes = Array(file.source.utf8)
        for mutant in file.mutants {
            let copy = String(
                decoding: bytes[mutant.instrumentedSpan.start..<mutant.instrumentedSpan.end],
                as: UTF8.self)
            #expect(copy.contains("\u{2028}"))
        }
    }

    private static func instrument(_ source: String) throws -> InstrumentedFile {
        let path = try #require(WorkspaceRelativePath("Sources/Subject.swift"))
        return try Instrument.file(source, discovery: Discover.candidates(in: source, at: path))
    }
}
