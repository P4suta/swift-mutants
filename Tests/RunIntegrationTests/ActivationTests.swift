// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

/// Which mutants a run actually wakes.
@Suite("Activation, on a real package")
struct ActivationTests {

    static func fixture() throws -> RunIntegrationTests.Fixture {
        try RunIntegrationTests.fixture()
    }

    static func write(_ contents: String, to file: URL) throws {
        try RunIntegrationTests.write(contents, to: file)
    }

    static func run(_ fixture: RunIntegrationTests.Fixture) async throws -> RunOutcome {
        try await RunIntegrationTests.run(fixture)
    }

    /// One environment variable, one mutant awake - put to a real package with two files.
    ///
    /// Every instrumented file reads the same `SWIFT_MUTANTS_ACTIVE`, so numbering each
    /// file from zero meant one value woke the same index in all of them. On this
    /// repository that was fifty-nine files at once, and what a run learned from wrecking
    /// a program fifty-nine ways it reported as a fact about one mutant.
    ///
    /// The observable is the symptom somebody would actually be harmed by: a survivor
    /// reported as a kill. `Second.swift` holds a mutant no test can catch, and
    /// `First.swift` holds one every test catches. With shared numbering, waking the
    /// survivor also wakes the other file's mutant, the first file's test fails, and the
    /// survivor is reported as killed - so a suite with a real hole in it scores full
    /// marks. Which is exactly what this repository did.
    @Test("wakes one mutant, not one in every file", .tags(.integration))
    func wakesExactlyOneMutant() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        // Two files and no others, so every mutant in the run belongs to one of them.
        try FileManager.default.removeItem(
            at: fixture.root.appending(path: "Sources/Subject/Subject.swift"))
        try Self.write(
            "public func first(_ a: Int, _ b: Int) -> Bool { return a >= b }",
            to: fixture.root.appending(path: "Sources/Subject/First.swift"))
        try Self.write(
            "public func second(_ a: Bool, _ b: Bool) -> Bool { return a && b }",
            to: fixture.root.appending(path: "Sources/Subject/Second.swift"))
        try Self.write(
            """
            import Testing
            @testable import Subject

            @Suite("Subject")
            struct SubjectTests {
                /// Catches anything done to `first`.
                @Test("first holds at the boundary") func firstBoundary() {
                    #expect(first(3, 3))
                    #expect(!first(2, 3))
                }
                /// Catches nothing done to either operand of `second`, because it only
                /// ever passes two trues.
                @Test("second is true when both are") func secondBoth() {
                    #expect(second(true, true))
                }
            }
            """, to: fixture.root.appending(path: "Tests/SubjectTests/SubjectTests.swift"))

        let outcome = try await Self.run(fixture)
        let byRule = Dictionary(
            grouping: outcome.results, by: { $0.rule.name }
        ).mapValues { $0.map(\.verdict.outcome) }

        // The one nothing can catch survives, and the one everything catches does not.
        #expect(byRule["and-keep-lhs"] == [.survived], "\(byRule)")
        #expect(byRule["and-keep-rhs"] == [.survived], "\(byRule)")
        #expect(byRule["ge-to-gt"] == [.killed], "\(byRule)")
        #expect(outcome.summary.survived >= 2, "\(outcome.summary)")
    }
}
