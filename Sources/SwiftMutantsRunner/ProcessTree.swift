// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Dispatch
import Synchronization

final class ProcessTree: Sendable {
    private struct Identity: Sendable, Hashable {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64

        static func read(_ pid: pid_t) -> Self? {
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            #if compiler(>=6.4)
            let count = withUnsafeMutablePointer(to: &info) {
                unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
            }
            #else
            let count = unsafe withUnsafeMutablePointer(to: &info) {
                unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
            }
            #endif
            guard count == size else { return nil }
            return Self(
                pid: pid,
                seconds: info.pbi_start_tvsec,
                microseconds: info.pbi_start_tvusec
            )
        }

        var isCurrent: Bool { Self.read(pid) == self }
    }

    private struct State: Sendable {
        var members: Set<Identity>
        var retired = false
        var stopped = false
    }

    private let state: Mutex<State>

    init(root: pid_t) {
        state = Mutex(State(members: Set(Identity.read(root).map { [$0] } ?? [])))
    }

    func observe() {
        state.withLock { state in
            guard !state.retired, !state.stopped else { return }
            state.members = Self.descendants(of: state.members, freezing: false)
        }
    }

    func stop(onStop: @Sendable () -> Void = {}) {
        state.withLock { state in
            guard !state.retired, !state.stopped else { return }
            state.stopped = true
            onStop()
            state.members = Self.descendants(of: state.members, freezing: true)
            for member in state.members where member.isCurrent { kill(member.pid, SIGKILL) }
        }
    }

    func retire() { state.withLock { $0.retired = true } }

    private static func descendants(of known: Set<Identity>, freezing: Bool) -> Set<Identity> {
        var owned = known
        var pending = Array(known)
        while let parent = pending.popLast() {
            guard parent.isCurrent else { continue }
            if freezing { kill(parent.pid, SIGSTOP) }
            for pid in children(of: parent.pid) {
                guard parent.isCurrent, let child = Identity.read(pid), child.pid != parent.pid
                else { continue }
                if owned.insert(child).inserted { pending.append(child) }
            }
        }
        return owned
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        let capacity = Int(proc_listchildpids(pid, nil, 0)) + 32
        guard capacity > 0, capacity < Int(Int32.max) / MemoryLayout<pid_t>.stride else {
            return []
        }
        var pids = [pid_t](repeating: 0, count: capacity)
        #if compiler(>=6.4)
        let received = pids.withUnsafeMutableBytes {
            unsafe proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
        }
        #else
        let received = unsafe pids.withUnsafeMutableBytes {
            unsafe proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
        }
        #endif
        return Array(pids.prefix(max(0, min(capacity, Int(received))))).filter { $0 > 0 }
    }
}

final class ProcessMonitor: Sendable {
    private struct State {
        var tree: ProcessTree?
        var timer: (any DispatchSourceTimer)?
        var cancelled = false
    }

    private let state = Mutex(State())
    private let timeout: Duration?
    private let expired: @Sendable () -> Void

    init(timeout: Duration?, expired: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.expired = expired
    }

    func start(root: pid_t) {
        state.withLock { state in
            let tree = ProcessTree(root: root)
            let end = timeout.map { ContinuousClock.now + $0 }
            let expired = expired
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "swift-mutants.process-monitor")
            )
            timer.schedule(deadline: .now(), repeating: .milliseconds(25))
            timer.setEventHandler {
                tree.observe()
                if let end, ContinuousClock.now >= end {
                    tree.stop(onStop: expired)
                }
            }
            state.tree = tree
            state.timer = timer
            timer.resume()
            if state.cancelled { tree.stop() }
        }
    }

    func cancel() {
        state.withLock {
            $0.cancelled = true
            $0.tree?.stop()
        }
    }

    func finish() {
        state.withLock {
            $0.tree?.stop()
            $0.tree?.retire()
            $0.timer?.cancel()
            $0.timer = nil
        }
    }
}
