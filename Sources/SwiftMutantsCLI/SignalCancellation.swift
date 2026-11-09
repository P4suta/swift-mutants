// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Darwin
import Dispatch
import Synchronization

final class SignalCancellation {
    private let state = SignalState()
    private var sources: [any DispatchSourceSignal] = []
    private var previous: [(Int32, sig_t?)] = []

    private init() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            previous.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [state] in
                let cancel = state.value.withLock {
                    if $0.number == nil { $0.number = number }
                    return $0.cancel
                }
                cancel?()
            }
            source.resume()
            sources.append(source)
        }
    }

    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let signals = SignalCancellation()
        defer { signals.restore() }
        let task = Task { try await operation() }
        let interrupted = signals.state.value.withLock {
            $0.cancel = { task.cancel() }
            return $0.number != nil
        }
        if interrupted { task.cancel() }
        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if let number = signals.state.value.withLock({ $0.number }) {
                throw ExitCode(128 + number)
            }
            return value
        } catch {
            if let number = signals.state.value.withLock({ $0.number }) {
                throw ExitCode(128 + number)
            }
            throw error
        }
    }

    private func restore() {
        state.value.withLock { $0.cancel = nil }
        for source in sources { source.cancel() }
        for (number, handler) in previous { signal(number, handler) }
    }
}

private final class SignalState: Sendable {
    struct Value: Sendable {
        var number: Int32?
        var cancel: (@Sendable () -> Void)?
    }
    let value = Mutex(Value())
}
