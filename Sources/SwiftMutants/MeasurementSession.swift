// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsRunner
import SwiftMutantsSnapshot
import SwiftMutantsTrace

struct MeasurementSession: Sendable {
    let temporary: URL
    let snapshot: Snapshot
    let options: RunOptions
    let progress: @Sendable (RunEvent) -> Void
    let runner: Runner
    let environment: [String: String]
    let executable: String

    init(
        package: URL,
        options: RunOptions,
        progress: @escaping @Sendable (RunEvent) -> Void,
        environment: [String: String] = Ambient.environment,
        executable: String = "/usr/bin/env",
        outputLimit: Int = 1 << 20
    ) throws {
        #if !os(macOS)
        throw MutationTestingError(
            stage: .input,
            diagnostic: "Measurement requires macOS 15 or later."
        )
        #else
        try Self.validate(options)
        let source = package.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: source.appending(path: "Package.swift").path)
        else {
            throw MutationTestingError(
                stage: .input,
                diagnostic:
                    "Expected a SwiftPM package with Package.swift; Xcode projects, Simulator, and UI tests aren't supported."
            )
        }
        temporary = FileManager.default.temporaryDirectory.appending(
            path: "swift-mutants-session-\(UUID().uuidString)"
        )
        self.options = options
        self.progress = progress
        self.runner = Runner(recorder: TraceRecorder(), outputLimit: outputLimit)
        self.environment = environment
        self.executable = executable
        progress(.stage(.snapshot))
        do {
            snapshot = try Snapshot.create(of: source, at: temporary.appending(path: "package"))
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw MutationTestingError(stage: .snapshot, diagnostic: "\(error)")
        }
        #endif
    }

    private static func validate(_ options: RunOptions) throws {
        guard (options.timeout ?? .seconds(1)) > .zero,
            (options.timeout ?? .seconds(1)) <= .seconds(Int64.max / 1000)
        else {
            throw MutationTestingError(
                stage: .input,
                diagnostic: "The timeout must be positive and fit in milliseconds."
            )
        }
        for pattern in options.include + options.exclude where Glob(pattern) == nil {
            throw MutationTestingError(
                stage: .input,
                diagnostic: "Invalid source pattern: \(pattern)"
            )
        }
        for pattern in options.filter + options.skip {
            do { _ = try NSRegularExpression(pattern: pattern) } catch {
                throw MutationTestingError(
                    stage: .input,
                    diagnostic: "Invalid test expression: \(pattern)"
                )
            }
        }
    }

    func clean() throws {
        do { try FileManager.default.removeItem(at: temporary) } catch {
            throw MutationTestingError(stage: .cleanup, diagnostic: "\(error)")
        }
    }

    func command(
        _ arguments: [String],
        kind: ProcessSpec.Kind,
        timeout: Duration,
        activation: UInt32? = nil,
        matchingLines: [OutputLinePattern] = []
    ) async throws -> ProcessOutcome {
        try Task.checkCancellation()
        var variables = environment
        variables["SWIFT_MUTANTS_ACTIVE"] = activation.map(String.init)
        let result = await runner.run(
            ProcessSpec(
                kind: kind,
                executable: executable,
                arguments: ["swift"] + arguments,
                directory: snapshot.root.path,
                environment: variables,
                timeout: timeout
            ),
            matchingLines: matchingLines
        )
        try Task.checkCancellation()
        return result
    }

    func requireSuccess(_ result: ProcessOutcome, stage: RunStage) throws {
        guard result.startFailure == nil, !result.timedOut, result.exitCode == 0 else {
            throw MutationTestingError(stage: stage, diagnostic: diagnostic(result))
        }
    }

    func diagnostic(_ result: ProcessOutcome) -> String {
        if let failure = result.startFailure { return "Couldn't start the command: \(failure)" }
        let reason = result.timedOut ? "Command timed out" : "Command exited \(result.exitCode)"
        return "\(reason)\n\(result.standardErrorText)\n\(result.standardOutputText)"
    }

    func verifySnapshot(
        expectedSources: [String: String],
        state: Snapshot,
        stage: RunStage = .measurement
    ) throws {
        do {
            let unexpected = try state.drift().map(\.rendered).filter { expectedSources[$0] == nil }
            guard unexpected.isEmpty else {
                throw MutationTestingError(
                    stage: stage,
                    diagnostic: "Tests changed package files: \(unexpected.joined(separator: ", "))"
                )
            }
            for (path, expected) in expectedSources {
                let bytes = try Data(contentsOf: snapshot.root.appending(path: path))
                guard bytes.elementsEqual(expected.utf8) else {
                    throw MutationTestingError(
                        stage: stage,
                        diagnostic: "Tests changed source: \(path)"
                    )
                }
            }
        } catch let failure as MutationTestingError {
            throw failure
        } catch {
            throw MutationTestingError(
                stage: stage,
                diagnostic: "Couldn't inspect package files after tests: \(error)"
            )
        }
    }
}

struct MutationSource: Sendable {
    let path: String
    let source: String
    let discovery: FileDiscovery
    let mutations: [Mutation]
}
