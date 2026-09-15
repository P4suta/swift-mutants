// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Synchronization

/// Watches who holds which token, and lets one worker wait for the rest to arrive.
///
/// The waiting is what makes the test a fact rather than a race: the worker that must
/// still be running when a later one starts is held until that later one has started,
/// so the overlap is arranged rather than hoped for. It is released by arrival rather
/// than by a clock, so the test is the same on a loaded machine as on an idle one, and
/// it terminates whether the thing under test is right or wrong.
///
/// Here rather than in one test target because the same property is asserted of the pool
/// itself and of each phase that takes its tokens from it, and those live apart.
public final class TokenWatch: Sendable {

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
    public init(releasingAfter quorum: Int) { self.quorum = quorum }

    /// Records that a worker has taken this token, and releases the waiter once
    /// enough of them have.
    public func arrive(_ token: Int) {
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

    /// Records that the worker holding this token has given it back.
    public func leave(_ token: Int) { state.withLock { _ = $0.live.remove(token) } }

    /// Waits until `quorum` workers have arrived, so that an overlap is arranged
    /// rather than hoped for.
    public func waitForTheRest() async {
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
    public var collided: Set<Int> { state.withLock { $0.collided } }

    /// Every token that was handed out.
    public var used: Set<Int> { state.withLock { $0.used } }
}
