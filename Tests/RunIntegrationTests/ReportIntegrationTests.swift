// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsEngine
import SwiftMutantsReport
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace

@testable import SwiftMutantsCLI
import Testing

/// The report a real run produces.
///
/// Everything about the shape is settled by unit tests over a fixture. What is not settled
/// there is whether a run actually carries what the shape needs - a report can be perfectly
/// formed and say `null` for every position because nothing ever put the line index in it,
/// and a fixture that supplies the index by hand would never notice.
@Suite("A report of a real run")
struct ReportIntegrationTests {

    @Test("says where every mutant is, from a run that read the files", .tags(.integration))
    func saysWhereEveryMutantIs() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let outcome = try await RunIntegrationTests.run(fixture)
        let report = RunReport(of: outcome)

        #expect(!report.mutants.isEmpty)
        // Every one of them, not most: a position that went missing would be a report
        // naming a place nobody can open.
        #expect(report.mutants.allSatisfy { $0.line.value != nil })
        #expect(report.mutants.allSatisfy { ($0.line.value ?? 0) > 0 })
        #expect(report.mutants.allSatisfy { ($0.column.value ?? 0) > 0 })
    }

    /// The kind of thing that is right in a type and absent from the pipeline: a mutant
    /// knows what it changed all the way from discovery, or it does not and every report
    /// says nothing twice.
    @Test("says what every mutant changed, from a run that read the files", .tags(.integration))
    func saysWhatEveryMutantChanged() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let report = RunReport(of: try await RunIntegrationTests.run(fixture))
        #expect(!report.mutants.isEmpty)
        #expect(report.mutants.allSatisfy { !$0.original.isEmpty })
        #expect(report.mutants.allSatisfy { !$0.replacement.isEmpty })
        #expect(report.mutants.allSatisfy { $0.original != $0.replacement })
    }

    /// The counts in the report are the run's counts, not a recount of the list - and the
    /// two must agree, or the summary a person reads is about a different run from the
    /// rows underneath it.
    @Test("adds up to what the run said", .tags(.integration))
    func addsUp() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let outcome = try await RunIntegrationTests.run(fixture)
        let report = RunReport(of: outcome)

        #expect(report.summary.killed == report.mutants.count { $0.outcome == "killed" })
        #expect(report.summary.survived == report.mutants.count { $0.outcome == "survived" })
        #expect(report.summary.rejected == report.rejected.count)
        #expect(report.filesInstrumented > 0)
    }

    /// Written, read back, and still the same run. A report nobody can parse is a report
    /// nobody has.
    @Test("survives being written and read again", .tags(.integration))
    func roundTrips() async throws {
        let fixture = try RunIntegrationTests.fixture()
        defer { fixture.cleanUp() }

        let report = RunReport(of: try await RunIntegrationTests.run(fixture))
        let data = try RunReport.encoded(report)
        let again = try JSONDecoder().decode(RunReport.self, from: data)

        #expect(again == report)
        #expect(try RunReport.encoded(again) == data)
    }
}

/// The command a report exists for.
///
/// A run's summary says how many things survived. `explain` is what turns one of those
/// rows into a task, and it reads what the run left behind rather than running anything -
/// so this is a test that a run really does leave it behind, and that what it left can be
/// read back and answered from.
@Suite("Explaining a survivor of a real run")
struct ExplainIntegrationTests {

    @Test("keeps a report the next command can answer from", .tags(.integration))
    func keepsSomethingToExplain() async throws {
        let fixture = try RunIntegrationTests.fixture()
        let store = ReportStore.location(for: fixture.root)
        defer {
            fixture.cleanUp()
            try? FileManager.default.removeItem(at: store)
        }
        try? FileManager.default.removeItem(at: store)

        let outcome = try await RunIntegrationTests.run(fixture)
        try ReportStore.write(RunReport(of: outcome), to: store)

        let read = try #require(ReportStore.read(from: store))
        let survivor = try #require(read.mutants.first { $0.outcome == "survived" })

        // The tests that looked at it and said nothing, by name. That list is the whole
        // task: one of them is where the missing assertion belongs.
        let ran = survivor.ran.map { read.tests[$0] }
        #expect(!ran.isEmpty, "a survivor nothing ran is a different finding")
        #expect(ran.allSatisfy { !$0.isEmpty })

        // And it says what it changed, so nobody has to open the file to find out.
        #expect(!survivor.original.isEmpty)
        #expect(survivor.original != survivor.replacement)
    }

    /// The identity a report prints is the one somebody types back.
    @Test("finds a mutant by the front of what a report printed", .tags(.integration))
    func findsWhatWasPrinted() async throws {
        let fixture = try RunIntegrationTests.fixture()
        let store = ReportStore.location(for: fixture.root)
        defer {
            fixture.cleanUp()
            try? FileManager.default.removeItem(at: store)
        }

        let report = RunReport(of: try await RunIntegrationTests.run(fixture))
        let wanted = try #require(report.mutants.first)

        #expect(Explanation.find(String(wanted.id.prefix(20)), among: report.mutants) == wanted)
    }
}

/// The command a report offers is a command that works.
///
/// Everything else about `explain` can be checked against a fixture. This cannot: the point
/// of the line is that pasting it runs the mutant, and the only way to know is to paste it.
@Suite("Reproducing a mutant from a real run")
struct ReproductionIntegrationTests {

    /// Run it, keep the tree, take a survivor, and run the line the report offers.
    ///
    /// The mutant survived, so the suite passes with it awake - which is what the command
    /// has to reproduce. A line that woke the wrong mutant, or none, would run a suite that
    /// also passes, so the test then wakes a mutant the run had killed and requires that
    /// the same command fails. Two directions, because only the pair of them says the
    /// variable is doing anything.
    @Test("the command a report offers runs the mutant it names", .tags(.integration))
    func theCommandRuns() async throws {
        let fixture = try RunIntegrationTests.fixture()
        let workspace = fixture.workspace
        defer { fixture.cleanUp() }

        let outcome = try await RunIntegrationTests.run(fixture)
        let report = RunReport(of: outcome, kept: true)
        #expect(report.invocation.isKnown)
        #expect(report.invocation.kept)

        let survivor = try #require(report.mutants.first { $0.outcome == "survived" })
        let killed = try #require(report.mutants.first { $0.outcome == "killed" })

        #expect(await Self.status(of: survivor, in: report) == 0)
        #expect(await Self.status(of: killed, in: report) != 0)
        _ = workspace
    }

    /// Runs the command the report offers for one mutant, and says what it exited with.
    ///
    /// Built from the report the way `explain` builds the line it prints, so what this runs
    /// is what somebody would paste.
    static func status(of mutant: RunReport.Mutant, in report: RunReport) async -> Int32 {
        let tests = mutant.ran.compactMap {
            report.tests.indices.contains($0) ? report.tests[$0] : nil
        }
        let spec = Launch(
            plan: TestPlan(
                executable: report.invocation.executable,
                arguments: report.invocation.arguments,
                environment: RunIntegrationTests.environment()
                    .merging(report.invocation.environment) { _, worked in worked },
                directory: report.invocation.directory,
                eventStreamVersion: report.invocation.eventStreamVersion
            ),
            worker: 0,
            timeout: .seconds(180)
        ).specification(
            writingEventsTo: "/dev/null",
            waking: [UInt32(clamping: mutant.index)],
            onlyTests: tests.isEmpty ? nil : tests
        )
        let outcome = await Runner(recorder: TraceRecorder()).run(spec)
        return Int32(outcome.exitCode)
    }
}
