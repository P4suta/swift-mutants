// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsExecute

/// A test whose reach could not be established.
///
/// The probe runs each test on its own and reads back which guards it evaluated. When one
/// of those runs does not finish - it ran out of time on a loaded machine, it crashed, its
/// log could not be read - the honest answer is that nothing is known about that test, and
/// the dangerous one is an empty set.
///
/// An empty set reads exactly like "this test reaches nothing", which is how a mutant that
/// the test catches every day comes back `survived` with no tests against its name. That is
/// the worst answer this tool can give: it is wrong, it is silent, and it points somebody
/// at working code and tells them to delete it. This is the test that says so; it exists
/// because a run under load produced exactly that, once.
@Suite("A probe that could not be trusted")
struct UntrustedProbeTests {

    static func coverage(unknown: [String]) -> Coverage {
        Coverage(
            byMutant: [1: ["known"]],
            reach: ["known": [1]],
            untrusted: unknown
        )
    }

    /// A test nobody could establish anything about might reach anything, so it is offered
    /// to everything. The cost is running it more often than necessary; the alternative is
    /// being wrong.
    @Test("offers a test it knows nothing about to every mutant")
    func offersTheUnknownToEveryone() {
        let coverage = Self.coverage(unknown: ["mystery"])
        #expect(coverage.tests(reaching: 1)?.contains("mystery") == true)
        #expect(coverage.tests(reaching: 2)?.contains("mystery") == true)
    }

    /// And it keeps the tests it does know about, rather than giving up on the whole map
    /// for one bad process.
    @Test("keeps what it did establish")
    func keepsWhatItKnows() {
        #expect(Self.coverage(unknown: ["mystery"]).tests(reaching: 1)?.contains("known") == true)
    }

    /// The claim that costs somebody their afternoon. "No test reaches this" has to mean
    /// it, and while any test's reach is unknown it cannot be said about anything.
    @Test("says nothing is unreachable while anything is unknown")
    func nothingIsUnreachableWhileAnythingIsUnknown() {
        #expect(Self.coverage(unknown: ["mystery"]).uncovered(among: [1, 2]) == 0)
    }

    /// The premise: with every probe trusted, the same mutant really is unreached.
    @Test("still says what nothing reaches when it established everything")
    func saysUnreachedWhenItKnows() {
        let coverage = Self.coverage(unknown: [])
        #expect(coverage.uncovered(among: [1, 2]) == 1)
        #expect(coverage.tests(reaching: 2) == nil)
    }

    /// Nothing established at all is not the same as nothing to establish. A run whose
    /// every probe failed must behave as though it had no coverage rather than as though
    /// no test reached anything.
    @Test("offers the whole suite when it established nothing at all")
    func everythingUnknown() {
        let coverage = Coverage(
            byMutant: [:], reach: [:], untrusted: ["a", "b"])
        #expect(coverage.tests(reaching: 1)?.sorted() == ["a", "b"])
        #expect(coverage.uncovered(among: [1, 2]) == 0)
    }
}

/// Asking a real process what it reached, and believing the answer only when there is one.
///
/// The distinction that matters is between a test that reached nothing and a process that
/// did not get to the end of its job. Both used to look the same - no log - so the prober
/// makes the log before it starts, and the runtime appends into it.
@Suite("What a probe establishes")
struct ProbeTrustTests {

    static func probe(_ fake: ScriptedBundle.Fake, timeout: Duration = .seconds(30)) -> Prober {
        Prober(
            plan: fake.plan,
            runner: SchedulerTests.runner(),
            scratch: fake.scratch,
            timeout: timeout,
            jobs: 1
        )
    }

    /// A bundle that runs cleanly and evaluates no guard has established something: this
    /// test reaches nothing.
    @Test("believes a clean run that recorded nothing")
    func nothingIsAnAnswer() async throws {
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        let coverage = await Self.probe(fake).probe(["P.S/a()"])
        #expect(coverage.untrusted.isEmpty)
        #expect(coverage.tests(reaching: 1) == nil)
        #expect(coverage.uncovered(among: [1]) == 1)
    }

    /// A bundle that exits non-zero did not get to the end of its job, whatever it managed
    /// to write first.
    @Test("believes nothing from a run that did not finish")
    func aFailedRunEstablishesNothing() async throws {
        let fake = try ScriptedBundle.fake(
            failingFor: [], failingBaselineTests: ["P.S/a()"])
        defer { fake.cleanUp() }

        let coverage = await Self.probe(fake).probe(["P.S/a()"])
        #expect(coverage.untrusted == ["P.S/a()"])
        #expect(coverage.uncovered(among: [1]) == 0)
    }

    /// And a run it never gets an answer out of at all.
    @Test("believes nothing from a run it had to stop")
    func aStoppedRunEstablishesNothing() async throws {
        let fake = try ScriptedBundle.fake(failingFor: [], alwaysSlow: [0])
        defer { fake.cleanUp() }

        let coverage = await Self.probe(fake, timeout: .milliseconds(1)).probe(["P.S/a()"])
        #expect(coverage.untrusted == ["P.S/a()"])
    }
}
