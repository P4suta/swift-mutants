// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Synchronization
import SwiftMutants
import Testing

@Suite("Public package measurement", .serialized)
struct MeasurementIntegrationTests {
    @Test(
        "measures Swift Testing, XCTest, and mixed targets",
        arguments: [
            PackageFixture.testing, PackageFixture.xctest,
            PackageFixture.testing + "\n" + PackageFixture.xctest,
        ]
    )
    func frameworks(tests: String) async throws {
        let package = try PackageFixture(tests: tests, extraTarget: true)
        defer { try? package.remove() }
        let builds = Mutex<[BuildKind]>([])
        let report = try await MutationTesting.run(packageAt: package.root) { event in
            if case .building(let kind) = event { builds.withLock { $0.append(kind) } }
        }
        #expect(report.summary.killed >= 1)
        #expect(report.summary.survived >= 1)
        #expect(report.summary.errored == 0)
        #expect(report.score != nil)
        #expect(builds.withLock { $0 } == [.original, .instrumented])
        let source = try String(
            contentsOf: package.root.appending(path: "Sources/Subject/Subject.swift"),
            encoding: .utf8
        )
        #expect(source == PackageFixture.source)
        #expect(
            !FileManager.default.fileExists(atPath: package.root.appending(path: ".build").path)
        )
        let mutations = try await MutationTesting.list(packageAt: package.root)
        #expect(Set(mutations.map(\.id)) == Set(report.results.map(\.mutation.id)))
        let survivor = try #require(report.results.first { $0.outcome == .survived })
        let rerun = try await MutationTesting.run(
            packageAt: package.root,
            options: RunOptions(mutantIDs: [survivor.mutation.id])
        )
        #expect(rerun.results.map(\.outcome) == [.survived])
    }
}
