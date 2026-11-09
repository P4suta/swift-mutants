// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Keeps executable products available to dependent packages.
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

    @Test("declares every executable target as a product")
    func everyExecutableIsAccountedFor() throws {
        let manifest = try Self.manifest()
        let declared = manifest.matches(of: /\.executableTarget\(\s*\n\s*name: "([^"]+)"/)
            .map { String($0.1) }
        let offered = manifest.matches(of: /\.executable\(name: "([^"]+)"/).map { String($0.1) }
        let unaccounted = Set(declared)
            .subtracting(offered)
            .sorted()
        #expect(
            unaccounted.isEmpty,
            """
            These executable targets have no product that another package can run: \
            \(unaccounted.joined(separator: ", "))
            """
        )
    }
}
