// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Synchronization

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
