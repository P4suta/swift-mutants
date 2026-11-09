// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import SwiftMutants

@Suite("Partial instrumentation", .serialized)
struct PartialInstrumentationIntegrationTests {
    @Test("one incompatible guard preserves compatible guards in the same file")
    func retainsCompatibleMutations() async throws {
        let package = try PackageFixture(tests: Self.tests, source: Self.source)
        defer { try? package.remove() }
        let mutations = try await MutationTesting.list(packageAt: package.root)
        #expect(mutations.count == 3)
        let incompatible = try #require(mutations.first { $0.line == 8 })
        let builds = Mutex<[BuildKind]>([])
        let measured = Mutex<[String]>([])
        let report = try await MutationTesting.run(packageAt: package.root) { event in
            if case .building(let kind) = event { builds.withLock { $0.append(kind) } }
            if case .measured(let result) = event {
                measured.withLock { $0.append(result.mutation.id) }
            }
        }
        let individuals = builds.withLock { kinds in
            kinds.compactMap { kind -> String? in
                if case .individual(let mutantID) = kind { return mutantID }
                return nil
            }
        }
        #expect(individuals == [incompatible.id])
        #expect(measured.withLock { $0.last } == incompatible.id)
        #expect(report.results.map(\.mutation.id) == mutations.map(\.id))
        #expect(report.results.map(\.outcome) == [.killed, .killed, .survived])

        let session = try MeasurementSession(
            package: package.root, options: RunOptions(), progress: { _ in }
        )
        defer { try? session.clean() }
        let individual = try await session.measure(instrumenting: false)
        #expect(individual.results.map(\.outcome) == report.results.map(\.outcome))
        #expect(individual.score == report.score)
        let unchanged = try String(
            contentsOf: package.root.appending(path: "Sources/Subject/Subject.swift"),
            encoding: .utf8
        )
        #expect(unchanged == Self.source)
    }

    private static let source = """
        public func add(_ a: Int, _ b: Int) -> Int { a + b }
        public protocol Value {}
        public struct Input { public init() {} }
        public struct Sum: Value {}
        public struct Difference: Value {}
        public func + (_ a: Input, _ b: Input) -> Sum { Sum() }
        public func - (_ a: Input, _ b: Input) -> Difference { Difference() }
        public func combine(_ a: Input, _ b: Input) -> some Value { a + b }
        public func scale(_ a: Int, _ b: Int) -> Int { a * b }
        """

    private static let tests = """
        import Testing
        import Subject
        @Test func adds() { #expect(add(2, 3) == 5) }
        @Test func typeIsSum() {
            #expect(String(describing: type(of: combine(Input(), Input()))) == "Sum")
        }
        """
}
