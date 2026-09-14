// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsInstrument
import Testing

@testable import SwiftMutantsExecute

/// Running a mutant again when the first answer was a deadline.
///
/// A killed mutant stops at the first test that notices it; a surviving mutant runs the
/// whole suite. So the mutants that meet a deadline are, overwhelmingly, the survivors -
/// and a deadline counts as a detection. Measured on this repository before any of this
/// existed: 592 mutants, 82 deadlines, 0 survivors reported, and a score of 100% that was
/// not true of anything.
@Suite("Retrying deadlines")
struct RetryTests {

    static func mutants() throws -> [InstrumentedMutant] { try SchedulerTests.mutants() }

    /// The reason retries exist, and it is not hypothetical.
    ///
    /// A killed mutant stops at the first test that notices it; a surviving mutant runs
    /// the whole suite. So the mutants that meet a deadline are, overwhelmingly, the
    /// survivors - and counting a deadline as a detection turns every one of them into a
    /// kill. Measured on this repository: 592 mutants, 82 deadlines, 0 survivors reported,
    /// and a score of 100%, which was not true of anything.
    @Test("runs a mutant that ran out of time again, and takes the second answer")
    func retriesTimeouts() async throws {
        let mutants = try Self.mutants()
        let fake = try SchedulerTests.fake(failingFor: [], slowUntilRetried: [mutants[2].index])
        defer { fake.cleanUp() }

        // A deadline the slow pass certainly misses and the quick one certainly meets.
        let results = await SchedulerTests.scheduler(fake, timeout: .milliseconds(700))
            .run(mutants, in: SchedulerTests.path())
        let retried = try #require(results.first { $0.identity == mutants[2].identity })
        #expect(retried.verdict.outcome == .survived)
        #expect(retried.attempts == 2)

        // Everything else was answered the first time.
        #expect(results.filter { $0.attempts > 1 }.count == 1)
    }

    /// A mutant that runs out of time twice, the second time alone, has earned it.
    @Test("keeps the verdict when a mutant runs out of time twice")
    func confirmedTimeout() async throws {
        let mutants = try Self.mutants()
        let fake = try SchedulerTests.fake(failingFor: [], alwaysSlow: [mutants[1].index])
        defer { fake.cleanUp() }

        let results = await SchedulerTests.scheduler(fake, timeout: .milliseconds(700))
            .run(mutants, in: SchedulerTests.path())
        let stuck = try #require(results.first { $0.identity == mutants[1].identity })
        #expect(stuck.verdict.outcome == .timedOut)
        #expect(stuck.attempts == 2)
    }
}

/// Running the baseline the way the mutants will be run.
@Suite("Contended baseline")
struct ContendedBaselineTests {

    /// A mutation run starts `jobs` copies of a suite against one machine. A suite that
    /// shares a port, a fixture directory or a temporary file with itself fails for
    /// reasons that have nothing to do with any mutant, and the failures would appear as
    /// a scattering of unexplained kills. Better to ask here.
    @Test("runs the baseline the way the mutants will be run")
    func contendedBaselineRunsEveryWorker() async throws {
        let fake = try SchedulerTests.fake(failingFor: [])
        defer { fake.cleanUp() }

        let verdicts = await SchedulerTests.scheduler(fake, jobs: 3).contendedBaseline()
        #expect(verdicts.count == 3)
        #expect(verdicts.allSatisfy { $0.outcome == .survived })

        // Each worker took a token of its own, which is what a suite that cannot share
        // needs in order to stop sharing.
        let tokens = try String(
            contentsOf: fake.scratch.appending(path: "tokens.txt"), encoding: .utf8
        ).split(separator: "\n").map(String.init)
        #expect(Set(tokens) == ["0", "1", "2"])
    }
}
