// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsInstrument

@Suite("Compiling a guard in a default argument", .tags(.integration))
struct DefaultArgumentCompileTests {

    static func compiles(
        _ source: String, extra: [String] = []
    ) throws -> (
        exitCode: Int32, text: String
    ) {
        let instrumented = try InlinableTests.instrument(source, named: "Subject")
        return try InlinableTests.compile(["Subject.swift": instrumented.source], extra: extra)
    }

    static let defaults = """
        public func page(wide: Bool = true, deep: Bool = false) -> Bool { wide && deep }

        @inlinable public func hot(wide: Bool = true) -> Bool { wide }

        public struct Box {
            public let wide: Bool
            public init(wide: Bool = true) { self.wide = wide }
        }
        """

    @Test("compiles a default argument in a public function, an inlinable one and an init")
    func compilesEveryShape() throws {
        let said = try Self.compiles(Self.defaults)
        #expect(said.exitCode == 0, "\(said.text)")
    }

    @Test("compiles them under library evolution")
    func underLibraryEvolution() throws {
        let said = try Self.compiles(Self.defaults, extra: ["-enable-library-evolution"])
        #expect(said.exitCode == 0, "\(said.text)")
    }

    @Test("puts a guard in the default argument it is about")
    func theGuardIsThere() throws {
        let instrumented = try InlinableTests.instrument(Self.defaults, named: "Subject")
        let line = instrumented.source.split(separator: "\n").first {
            $0.contains("public func page")
        }
        #expect(line?.contains("__sm_") == true, "\(line ?? "no such line")")
    }
}
