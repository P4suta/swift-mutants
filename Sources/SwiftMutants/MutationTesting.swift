// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Discovers and measures mutations in a disposable SwiftPM package snapshot.
public enum MutationTesting {
    /// Lists mutations without building the package's targets or changing its source tree.
    public static func list(
        packageAt package: URL,
        include: [String] = [],
        exclude: [String] = []
    ) async throws -> [Mutation] {
        try await withSession(
            package: package,
            options: RunOptions(include: include, exclude: exclude)
        ) {
            try await $0.discover().flatMap(\.mutations)
        }
    }

    /// Measures existing Swift Testing and XCTest tests with one mutation active at a time.
    /// Throws `MutationTestingError` for failed prerequisites and `CancellationError` after subprocess cleanup.
    /// The library installs no signal handlers and writes no console output.
    public static func run(
        packageAt package: URL,
        options: RunOptions = RunOptions(),
        progress: @escaping @Sendable (RunEvent) -> Void = { _ in }
    ) async throws -> MutationReport {
        try await withSession(package: package, options: options, progress: progress) {
            try await $0.measure()
        }
    }

    private static func withSession<Value: Sendable>(
        package: URL,
        options: RunOptions,
        progress: @escaping @Sendable (RunEvent) -> Void = { _ in },
        body: (MeasurementSession) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let session = try MeasurementSession(package: package, options: options, progress: progress)
        let value: Value
        do {
            value = try await body(session)
        } catch {
            let failure = error
            do { try session.clean() } catch {
                throw MutationTestingError(
                    stage: .cleanup,
                    diagnostic: "\(failure); snapshot cleanup failed: \(error)"
                )
            }
            throw failure
        }
        try session.clean()
        return value
    }
}
