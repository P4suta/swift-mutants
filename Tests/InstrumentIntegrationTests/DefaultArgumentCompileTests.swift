// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsInstrument

/// The compiler's opinion of a guard inside a default argument value.
///
/// These were passed over because Swift refuses a default argument value that references a
/// `private` declaration, and the runtime this tool appends was private. The runtime stopped
/// being private for an unrelated reason - an `@inlinable` function may not reference a
/// private symbol either - and that fixed this as a side effect, which nobody noticed for
/// as long as the rule kept the case from ever reaching a compiler.
///
/// So the compiler is asked directly, in all four shapes that could have been the exception:
/// a public function, an `@inlinable` one, an initialiser, and library evolution, which is
/// the strictest of them. The rule was removed on the strength of this suite.
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

    /// The strictest of the four, and the one where a symbol's visibility is checked hardest.
    @Test("compiles them under library evolution")
    func underLibraryEvolution() throws {
        let said = try Self.compiles(Self.defaults, extra: ["-enable-library-evolution"])
        #expect(said.exitCode == 0, "\(said.text)")
    }

    /// The premise. Without a guard actually landing in a default argument, both of the
    /// above would be compiling an ordinary file and saying nothing about this at all.
    @Test("puts a guard in the default argument it is about")
    func theGuardIsThere() throws {
        let instrumented = try InlinableTests.instrument(Self.defaults, named: "Subject")
        let line = instrumented.source.split(separator: "\n").first {
            $0.contains("public func page")
        }
        #expect(line?.contains("__sm_") == true, "\(line ?? "no such line")")
    }
}
