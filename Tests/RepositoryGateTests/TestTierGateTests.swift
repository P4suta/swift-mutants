// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Keeps target names and toolchain use aligned with the test tiers.
@Suite("Test tier gate")
struct TestTierGateTests {

    static let tierSuffixes = ["ToolchainTests", "IntegrationTests", "Tests"]

    @Test("every test target's name declares its tier")
    func targetsDeclareTheirTier() throws {
        let untiered = try Self.testTargetNames()
            .filter { name in !Self.tierSuffixes.contains(where: name.hasSuffix) }
            .sorted()
        #expect(
            untiered.isEmpty,
            """
            A test target's name is how `mise run test:unit` knows whether to run it. \
            End it in `Tests` (unit), `IntegrationTests` (needs a Swift toolchain) or \
            `ToolchainTests` (needs Xcode or a simulator).
            Untiered: \(untiered.joined(separator: ", "))
            """
        )
    }

    /// Unit tests may use processes but must not launch the Swift toolchain.
    static let toolchainReaches = ["ToolchainGate"]

    @Test("no unit-tier target reaches for a toolchain")
    func unitTierIsToolchainFree() throws {
        let unitTargets = try Self.testTargetNames()
            .filter { $0.hasSuffix("Tests") }
            .filter { !$0.hasSuffix("IntegrationTests") && !$0.hasSuffix("ToolchainTests") }

        // This file names every needle it searches for, so it would report itself.
        let selfPath = RepositoryGate.repositoryRelativePath(URL(filePath: #filePath))
        var offences: [String] = []
        for target in unitTargets {
            for file in try RepositoryGate.swiftFiles(under: "Tests/\(target)")
            where RepositoryGate.repositoryRelativePath(file) != selfPath {
                let code = try RepositoryGate.codeLines(of: file)
                for reach in Self.toolchainReaches where code.contains(reach) {
                    offences.append("\(RepositoryGate.repositoryRelativePath(file)): \(reach)")
                }
            }
        }
        #expect(
            offences.isEmpty,
            """
            The unit tier must not start a toolchain. Move the test into a target whose \
            name ends in `IntegrationTests`, or use process fixtures instead.
            \(offences.sorted().joined(separator: "\n"))
            """
        )
    }

    /// A `.testTarget` cannot depend on another test target.
    static let testSupportTargets = ["SwiftMutantsTestKit"]

    /// Whether a file belongs to a target that is test support despite living under `Sources/`.
    static func isTestSupport(_ file: URL) -> Bool {
        let path = RepositoryGate.repositoryRelativePath(file)
        return testSupportTargets.contains { path.hasPrefix("Sources/\($0)/") }
    }

    /// Test support must not reach shipped code, in either direction.
    @Test("production code never imports the test kit")
    func testKitStaysOutOfProduction() throws {
        var offenders: [String] = []
        for file in try RepositoryGate.swiftFiles(under: "Sources")
        where !Self.isTestSupport(file) {
            if try RepositoryGate.codeLines(of: file).contains("import SwiftMutantsTestKit") {
                offenders.append(RepositoryGate.repositoryRelativePath(file))
            }
        }
        #expect(
            offenders.isEmpty,
            """
            SwiftMutantsTestKit is test support. Importing it from shipped code links a \
            testing framework and its flag registrations into swift-mutants itself.
            Offenders: \(offenders.joined(separator: ", "))
            """
        )
    }

    private static func testTargetNames() throws -> [String] {
        let manifest = try String(
            contentsOf: RepositoryGate.root.appending(path: "Package.swift"),
            encoding: .utf8
        )
        let declaration = /\.testTarget\(\s*name:\s*"([A-Za-z0-9_]+)"/
        return manifest.matches(of: declaration).map { String($0.1) }
    }
}
