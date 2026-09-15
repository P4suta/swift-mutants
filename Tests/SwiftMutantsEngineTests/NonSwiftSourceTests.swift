// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsEngine

/// What a package's non-Swift sources amount to.
///
/// A target holding C is a `library` target like any other, so `swift package describe`
/// lists its `.c` and `.h` files beside the Swift. Parsed as Swift they are not an error -
/// swift-syntax reads `#define` and `#include` as macro expansions, which this tool skips -
/// so a package vendoring a C dependency got a per-line `macro-expansion` skip for somebody
/// else's preprocessor, reported as a finding about their own code.
///
/// Measured on a package vendoring Argon2: 79 of its 205 skips, and the first thing its
/// author did to `list --explain` was grep them out.
@Suite("A package with C in it")
struct NonSwiftSourceTests {

    /// The wiring, not the predicate. A package vendoring C declares it as a `.target`,
    /// which SwiftPM describes as a library like any other - so its `.c` files reach the
    /// same loop the Swift does.
    @Test("reads no candidates out of a C file, and still digests it")
    func ignoresC() async throws {
        let fixture = try ListerTests.fixture(
            [
                "Sources/Core/Compare.swift": "func f(_ a: Int, _ b: Int) -> Bool { a < b }",
                // Valid C, and not valid Swift. Parsed as Swift it produces a
                // `macro-expansion` skip per directive rather than an error, which is why
                // this went unnoticed: the output looked like findings.
                "Sources/Core/blake2.c":
                    "#include <stdint.h>\n#define R 16\nint f(int a, int b) { return a < b; }\n",
            ],
            describing: """
                {"name":"Core","type":"library","path":"$ROOT/Sources/Core",
                 "sources":["Compare.swift","blake2.c"]}
                """
        )
        defer { fixture.cleanUp() }

        let listing = try await ListerTests.list(fixture)
        #expect(listing.filesRead == 1)
        #expect(listing.catalog.mutants.map(\.rule.name) == ["lt-to-le"])
        #expect(listing.skips.isEmpty, "\(listing.skips.map(\.skip.reason))")

        // Digested all the same: a cached answer rests on everything it depends on, and a
        // C file changing changes the program as surely as a Swift one does.
        #expect(listing.digests.keys.contains { $0.rendered.hasSuffix("blake2.c") })
    }

    @Test(
        "knows a Swift file from everything else",
        arguments: [
            ("Sources/Core/Core.swift", true),
            ("Sources/CArgon2/blake2.c", false),
            ("Sources/CArgon2/include/argon2.h", false),
            ("Sources/Core/Resources/model.json", false),
            ("Sources/Core/swift", false),
        ])
    func knowsSwift(named: String, isSwift: Bool) {
        guard let path = WorkspaceRelativePath(named) else {
            Issue.record("malformed fixture path \(named)")
            return
        }
        #expect(path.isSwift == isSwift)
    }
}
