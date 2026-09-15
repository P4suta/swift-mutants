// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsInstrument
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsExecute

/// A host that does nothing but record the token it was given.
///
/// No processes and no files: the question is which token a phase hands to a worker while
/// another worker still has one, and that is answered in memory.
struct Recording: MutantHost {

    let token: Int
    let watch: TokenWatch

    /// The mutant, or the test, that has to still be running when the others have started.
    let holding: UInt32

    /// The test that has to still be running, for the phase that probes rather than runs.
    let holdingTest: String

    init(token: Int, watch: TokenWatch, holding: UInt32 = .max, holdingTest: String = "") {
        self.token = token
        self.watch = watch
        self.holding = holding
        self.holdingTest = holdingTest
    }

    func run(
        waking indices: [UInt32],
        onlyTests: [String]?,
        settling: StreamWatcher.Settlement
    ) async -> Verdict {
        watch.arrive(token)
        if indices.contains(holding) { await watch.waitForTheRest() }
        watch.leave(token)
        return Verdict(
            outcome: .survived,
            killedBy: [],
            firstFailure: nil,
            startedTests: ["Subject.everything()"],
            durationMilliseconds: 1,
            termination: .exited(0)
        )
    }

    func probe(_ test: String, writingTo log: URL) async -> Int? {
        watch.arrive(token)
        if test == holdingTest { await watch.waitForTheRest() }
        watch.leave(token)
        // Nothing written, so the caller reads an empty log: this test reached nothing.
        // What it reached is not the question here.
        return 1
    }
}

/// What a worker token is for, and what it costs to hand the same one out twice.
///
/// A token is how a worker says which copy of the suite it is. A non-hermetic suite keys
/// its database, its port and its temporary directory on it; the Xcode path keys a
/// derived-data directory on it; a probe names its log after it. Two workers holding one
/// token at the same time are two workers writing to one directory, and what that produces
/// is a scattering of failures that look exactly like kills - a mutant reported as caught
/// because another worker deleted the fixture it was reading.
///
/// Both phases that start test processes used to derive the token from the position of the
/// work rather than from which worker was free: item `n` got `n % jobs`. Work starts as
/// earlier work finishes and it does not finish in order, so item `jobs` - which takes the
/// token of item 0 - starts the moment *any* of the first batch finishes. With eight jobs
/// and any variance at all in how long a mutant takes, the collision happens on essentially
/// every run.
///
/// ``WorkerPoolTests`` asserts that the pool is right. These assert that each phase takes
/// its tokens from the pool, which is a different claim and the one that catches a caller
/// going back to arithmetic.
@Suite("Worker tokens")
struct WorkerTokenTests {

    static func scheduler(jobs: Int, watch: TokenWatch, holding: UInt32) -> Scheduler {
        Scheduler(
            host: { worker, _ in Recording(token: worker, watch: watch, holding: holding) },
            jobs: jobs
        )
    }

    /// Two jobs and three mutants, with the first held open until the third has started.
    ///
    /// The third is the one that took `2 % 2 == 0` - the token of a worker that is still
    /// running, because the *second* is what finished and freed a slot.
    @Test("gives a mutant no token another mutant is still holding")
    func schedulerTokensAreNotShared() async throws {
        let mutants = Array(try SchedulerTests.mutants().prefix(3))
        let watch = TokenWatch(releasingAfter: 3)
        let scheduler = Self.scheduler(jobs: 2, watch: watch, holding: mutants[0].index)

        let results = await scheduler.run(mutants)

        #expect(results.count == mutants.count)
        #expect(
            watch.collided.isEmpty,
            """
            tokens \(watch.collided.sorted()) were held by two workers at once, so two \
            copies of the suite shared whatever the token separates
            """
        )
    }

    /// The other half of the same property, and the reason a token is not simply the unit
    /// number: a run of ten thousand mutants must not want ten thousand scratch
    /// directories. Tokens are a pool of `jobs`, taken and given back.
    @Test("gives a mutant no token outside the pool")
    func schedulerTokensStayInThePool() async throws {
        let mutants = try SchedulerTests.mutants()
        let watch = TokenWatch(releasingAfter: mutants.count)
        let scheduler = Self.scheduler(jobs: 2, watch: watch, holding: mutants[0].index)

        _ = await scheduler.run(mutants)
        #expect(watch.used.isSubset(of: [0, 1]), "used tokens \(watch.used.sorted())")
    }

    /// The same for the probe, where the stake is higher.
    ///
    /// A probe writes its log under its token. Two probes sharing one is a probe that
    /// establishes nothing about its test, and a test nothing was established about is
    /// offered to no mutant - which turns a mutant it catches every day into a survivor,
    /// silently, in the direction that reads as a hole in somebody's suite.
    @Test("gives a probe no token another probe is still holding")
    func proberTokensAreNotShared() async throws {
        let tests = ["Pkg.A/one()", "Pkg.A/two()", "Pkg.A/three()"]
        let watch = TokenWatch(releasingAfter: tests.count)
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "swift-mutants-probe-tokens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let prober = Prober(
            host: { worker in
                Recording(token: worker, watch: watch, holdingTest: tests[0])
            },
            scratch: scratch,
            jobs: 2
        )
        let probed = await prober.probe(tests)

        #expect(probed.coverage.reach.count == tests.count)
        #expect(
            watch.collided.isEmpty,
            "tokens \(watch.collided.sorted()) were held by two probes at once")
        #expect(watch.used.isSubset(of: [0, 1]), "used tokens \(watch.used.sorted())")
    }
}
