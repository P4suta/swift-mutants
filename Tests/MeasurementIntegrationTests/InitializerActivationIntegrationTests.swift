// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutants

@Suite("Initializer activation", .serialized)
struct InitializerActivationIntegrationTests {
    @Test("stored property guards agree with individual edits")
    func storedProperty() async throws {
        let package = try PackageFixture(
            tests: """
                import Testing
                import Subject
                @Test func startsDisabled() { #expect(!Flag().enabled) }
                """,
            source: """
                public final class Flag {
                    public var enabled = false
                    public init() {}
                }
                """
        )
        defer { try? package.remove() }
        let guarded = try await MutationTesting.run(packageAt: package.root)
        let session = try MeasurementSession(
            package: package.root, options: RunOptions(), progress: { _ in })
        defer { try? session.clean() }
        let individual = try await session.measure(instrumenting: false)
        #expect(individual.results.map(\.outcome) == [.killed])
        #expect(guarded.results.map(\.outcome) == individual.results.map(\.outcome))
    }
}
