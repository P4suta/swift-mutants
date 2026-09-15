// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsInstrument
import Synchronization
import Testing

@testable import SwiftMutantsExecute

/// What a worker token is for, and what it costs to hand the same one out twice.
///
/// A token is how a worker says which copy of the suite it is. A non-hermetic suite keys
/// its database, its port and its temporary directory on it; the Xcode path keys a
/// derived-data directory on it. Two workers holding one token at the same time are two
/// workers writing to one directory, and what that produces is a scattering of failures
/// that look exactly like kills - a mutant reported as caught because another worker
/// deleted the fixture it was reading.
///
/// The scheduler used to derive the token from the position of the unit rather than from
/// which worker was free: unit `n` got `n % jobs`. Units start as earlier ones finish and
/// they do not finish in order, so unit `jobs` - which takes the token of unit 0 - starts
/// the moment *any* of the first batch finishes. With eight jobs and any variance at all
/// in how long a mutant takes, that collision happens on essentially every run.
/// Watches who holds which token, and lets one worker wait for the rest to arrive.
///
/// The waiting is what makes the test a fact rather than a race: the worker that must
/// still be running when a later one starts is held until that later one has started,
/// so the overlap is arranged rather than hoped for. It is released by arrival rather
/// than by a clock, so the test is the same on a loaded machine as on an idle one, and
/// it terminates whether the scheduler is right or wrong.
final class TokenWatch: Sendable {

    private struct State {
        var live: Set<Int> = []
        var collided: Set<Int> = []
        var used: Set<Int> = []
        var arrived = 0
        var blocked: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())
    private let quorum: Int

    /// Releases the waiter once this many workers have started.
    init(releasingAfter quorum: Int) { self.quorum = quorum }

    func arrive(_ token: Int) {
        let release: CheckedContinuation<Void, Never>? = state.withLock { state in
            if state.live.contains(token) { state.collided.insert(token) }
            state.live.insert(token)
            state.used.insert(token)
            state.arrived += 1
            guard state.arrived >= quorum else { return nil }
            let waiting = state.blocked
            state.blocked = nil
            return waiting
        }
        release?.resume()
    }

    func leave(_ token: Int) { state.withLock { $0.live.remove(token) } }

    func waitForTheRest() async {
        let now = state.withLock { $0.arrived >= quorum }
        guard !now else { return }
        await withCheckedContinuation { continuation in
            let already = state.withLock { state -> Bool in
                guard state.arrived < quorum else { return true }
                state.blocked = continuation
                return false
            }
            if already { continuation.resume() }
        }
    }

    /// Tokens two workers held at the same moment.
    var collided: Set<Int> { state.withLock { $0.collided } }

    /// Every token that was handed out.
    var used: Set<Int> { state.withLock { $0.used } }
}

/// A host that does nothing but record the token it was given.
///
/// No processes and no files: the question is which token the scheduler hands to a
/// worker while another worker still has one, and that is answered in memory.
struct Recording: MutantHost {

    let token: Int
    let watch: TokenWatch

    /// The mutant that has to still be running when the others have started.
    let holding: UInt32

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

    func probe(_ test: String, writingTo log: URL) async -> Int? { 0 }
}

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
    @Test("never hands a token to a second worker while the first still holds it")
    func tokensAreNotSharedWhileLive() async throws {
        let mutants = Array(try SchedulerTests.mutants().prefix(3))
        let watch = TokenWatch(releasingAfter: mutants.count)
        let scheduler = Self.scheduler(jobs: 2, watch: watch, holding: mutants[0].index)

        let results = await scheduler.run(mutants, in: SchedulerTests.path())

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
    @Test("hands out no token outside the pool it was given")
    func tokensStayInThePool() async throws {
        let mutants = try SchedulerTests.mutants()
        let watch = TokenWatch(releasingAfter: mutants.count)
        let scheduler = Self.scheduler(jobs: 2, watch: watch, holding: mutants[0].index)

        _ = await scheduler.run(mutants, in: SchedulerTests.path())
        #expect(watch.used.isSubset(of: [0, 1]), "used tokens \(watch.used.sorted())")
    }
}
