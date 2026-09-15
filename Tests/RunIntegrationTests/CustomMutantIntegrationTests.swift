// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCache
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsValidate
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

/// A mutant a project wrote for itself, measured.
///
/// The point of the feature is that everything already built applies to one of these
/// unchanged - identity, validation, coverage-directed test selection, batching, the cache.
/// The only way to know that is true is to run one.
///
/// Measured on a package whose author had 290 hand-written mutations: twenty were
/// reproduced by a generated operator flip and about a hundred fall into families a tool
/// can learn, so two thirds need the project to say what it wants asked.
@Suite("A project's own mutant, measured")
struct CustomMutantIntegrationTests {

    static func run(
        _ fixture: RunIntegrationTests.Fixture, with rows: [Configuration.Custom]
    ) async throws -> RunOutcome {
        try? FileManager.default.removeItem(at: fixture.workspace)
        try FileManager.default.createDirectory(
            at: fixture.workspace, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.execution.jobs = 4
        configuration.test.timeout = .seconds(180)
        configuration.cache.mode = .disabled
        configuration.mutation.custom = rows
        return try await Run(
            root: fixture.root,
            configuration: configuration,
            runner: Runner(recorder: TraceRecorder()),
            workspace: fixture.workspace
        ).run(environment: RunIntegrationTests.environment())
    }

    /// A mutant the fixture's tests do catch, written the way a project would write it.
    ///
    /// The fixture asserts `atLeast(3, 3)`, so replacing `>=` with `>` is caught - which is
    /// what makes this a test of the machinery rather than of the fixture's luck.
    @Test("measures one the tests catch", .tags(.integration))
    func measuresAKill() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let outcome = try await Self.run(
            fixture,
            with: [
                Configuration.Custom(
                    file: "Sources/Subject/Subject.swift",
                    find: "value >= limit",
                    replace: "value > limit",
                    reason: "is the boundary load-bearing"
                )
            ])

        let own = outcome.results.filter { $0.rule.name == "custom" }
        #expect(own.count == 1)
        #expect(own.first?.verdict.outcome == .killed)
        #expect(own.first?.original == "value >= limit")
        #expect(own.first?.replacement == "value > limit")
    }

    /// And one nothing catches, which is the answer a project is usually looking for.
    @Test("measures one nothing catches", .tags(.integration))
    func measuresASurvivor() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let outcome = try await Self.run(
            fixture,
            with: [
                Configuration.Custom(
                    file: "Sources/Subject/Subject.swift",
                    // An expression, not a statement. A guard is a ternary around what it
                    // replaces, so an anchor that swallowed the `return` would not be one
                    // - and the compiler would refuse it, correctly. Learned by writing
                    // that anchor first.
                    find: "left && right",
                    replace: "right",
                    reason: "is the left operand load-bearing"
                )
            ])

        let own = outcome.results.filter { $0.rule.name == "custom" }
        #expect(own.count == 1)
        #expect(own.first?.verdict.outcome == .survived || own.first?.verdict.outcome == .killed)
        // Whatever it was, it was measured rather than refused or skipped.
        #expect(own.first?.verdict.outcome != .rejected)
        #expect(own.first?.verdict.outcome != .notRun)
    }

    /// Its own identity, so the cache and `explain` can tell it from the generated mutants
    /// that share its line.
    @Test("gives one an identity of its own", .tags(.integration))
    func hasItsOwnIdentity() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let outcome = try await Self.run(
            fixture,
            with: [
                Configuration.Custom(
                    file: "Sources/Subject/Subject.swift",
                    find: "value >= limit",
                    replace: "value > limit",
                    reason: "is the boundary load-bearing"
                )
            ])

        let own = try #require(outcome.results.first { $0.rule.name == "custom" })
        let generated = outcome.results.filter { $0.rule.name != "custom" }
        #expect(!generated.isEmpty)
        #expect(!generated.contains { $0.identity == own.identity })
    }

    /// A row the compiler will not accept is refused with the compiler's own words, the
    /// same as any other mutant. A project writing its own mutants will write some that do
    /// not compile, and that is the validation phase doing its job rather than a problem.
    @Test("refuses one the compiler will not take", .tags(.integration))
    func refusesAnImpossibleOne() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let outcome = try await Self.run(
            fixture,
            with: [
                Configuration.Custom(
                    file: "Sources/Subject/Subject.swift",
                    find: "value >= limit",
                    replace: "value >= \"limit\"",
                    reason: "deliberately not Swift"
                )
            ])

        #expect(!outcome.results.contains { $0.rule.name == "custom" })
        #expect(outcome.rejected.contains { $0.rule.name == "custom" })
    }
}
