// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// What this repository offers to a package that depends on it.
///
/// A tool nobody outside this repository can start is not a tool. `swift-mutants` was an
/// `executableTarget` and not a product for long enough that somebody trying to wire it
/// into their own gate could not: `swift run --package-path ../swift-mutants swift-mutants`
/// finds no such product, a dependency cannot reach it, and `swift build --product` has no
/// name to accept. They left the gate out of their repository rather than write a task that
/// quietly does nothing, which is the right call and a bad outcome.
///
/// Read out of the manifest rather than by building, because this tier runs in seconds and
/// the question is what the manifest declares. The release gate builds it for real.
@Suite("What this package offers")
struct ProductGateTests {

    static func manifest() throws -> String {
        try String(
            contentsOf: RepositoryGate.root.appending(path: "Package.swift"), encoding: .utf8)
    }

    @Test("offers the tool as something another package can run")
    func offersTheExecutable() throws {
        let manifest = try Self.manifest()
        #expect(
            manifest.contains(#".executable(name: "swift-mutants", targets: ["swift-mutants"])"#),
            "Package.swift declares no executable product for the tool"
        )
    }

    /// Every executable target is either a product or deliberately not one. The scripted
    /// toolchain is the second: it exists to be put on a test's `PATH` under the names
    /// `swift` and `xcodebuild`, and nobody should be depending on it.
    @Test("declares every executable target as a product, or means not to")
    func everyExecutableIsAccountedFor() throws {
        let manifest = try Self.manifest()
        let declared = manifest.matches(of: /\.executableTarget\(\s*\n\s*name: "([^"]+)"/)
            .map { String($0.1) }
        let offered = manifest.matches(of: /\.executable\(name: "([^"]+)"/).map { String($0.1) }
        let deliberatelyInternal = ["swift-mutants-fake-toolchain"]

        let unaccounted = Set(declared)
            .subtracting(offered)
            .subtracting(deliberatelyInternal)
            .sorted()
        #expect(
            unaccounted.isEmpty,
            """
            These executable targets are neither products nor written down as internal, so \
            nobody outside this repository can run them and nobody here decided that: \
            \(unaccounted.joined(separator: ", "))
            """
        )
    }
}
