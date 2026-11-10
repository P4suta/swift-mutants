// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutants

@Suite("Source byte preservation", .serialized)
struct SourceBytesIntegrationTests {
    @Test("invalid UTF-8 source fails discovery without changing its bytes")
    func invalidEncoding() async throws {
        let package = try PackageFixture(tests: PackageFixture.testing)
        defer { try? package.remove() }
        let file = package.root.appending(path: "Sources/Subject/Subject.swift")
        let bytes = Data([0xFF, 0x0A])
        try bytes.write(to: file)
        do {
            _ = try await MutationTesting.list(packageAt: package.root)
            Issue.record("Invalid UTF-8 source was accepted")
        } catch let failure as MutationTestingError {
            #expect(failure.stage == .discovery)
            #expect(failure.diagnostic.contains("UTF-8"))
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("package discovery and measurement preserve UTF-8 BOM and CRLF bytes")
    func byteOrderMark() async throws {
        let source = "\u{FEFF}public func enabled() -> Bool { false }\r\n"
        let package = try PackageFixture(
            tests: """
                import Testing
                import Subject
                @Test func disabled() { #expect(!enabled()) }
                """,
            source: source)
        defer { try? package.remove() }
        let path = "Sources/Subject/Subject.swift"
        let original = try Data(contentsOf: package.root.appending(path: path))
        try #require(original.elementsEqual(source.utf8))
        let mutations = try await MutationTesting.list(packageAt: package.root)
        #expect(mutations == (try Mutation.discover(in: source, at: path)))
        let guarded = try await MutationTesting.run(packageAt: package.root)
        let session = try MeasurementSession(
            package: package.root, options: RunOptions(), progress: { _ in })
        defer { try? session.clean() }
        let individual = try await session.measure(instrumenting: false)
        #expect(guarded.results.map(\.outcome) == [.killed])
        #expect(individual.results.map(\.outcome) == [.killed])
        #expect(try Data(contentsOf: package.root.appending(path: path)) == original)
    }
}
