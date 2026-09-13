// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Keeps the test tiers from blurring into each other.
///
/// The inner loop is only an inner loop while it stays in seconds, and it stays in seconds
/// only while nothing in it starts `swift` or `xcodebuild`. A tier that a task selects by
/// listing target names goes stale the moment somebody adds a target, and it goes stale
/// silently - in the direction that either skips a suite or slows the loop to a crawl.
/// So the tier is carried by the target's own name and asserted here.
///
/// | Suffix               | Tier        | Needs                                  |
/// | -------------------- | ----------- | -------------------------------------- |
/// | `Tests`              | unit        | nothing: pure code and fake toolchains |
/// | `IntegrationTests`   | integration | a real Swift toolchain                 |
/// | `ToolchainTests`     | toolchain   | Xcode, a simulator                     |
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

    /// A unit-tier target that shells out to the toolchain would pass this gate's name
    /// check and then quietly cost the inner loop a build. The source is checked too.
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
                for reach in [
                    "ToolchainGate.run", "Process(", "xcodebuild", "swift build", "swift test",
                ]
                where code.contains(reach) {
                    offences.append("\(RepositoryGate.repositoryRelativePath(file)): \(reach)")
                }
            }
        }
        #expect(
            offences.isEmpty,
            """
            The unit tier must not start a toolchain. Move the test into a target whose \
            name ends in `IntegrationTests`, or drive a fake toolchain instead.
            \(offences.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Test support must not reach shipped code, in either direction.
    @Test("production code never imports the test kit")
    func testKitStaysOutOfProduction() throws {
        var offenders: [String] = []
        for file in try RepositoryGate.swiftFiles(under: "Sources")
        where !RepositoryGate.repositoryRelativePath(file).hasPrefix("Sources/SwiftMutantsTestKit/")
        {
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
