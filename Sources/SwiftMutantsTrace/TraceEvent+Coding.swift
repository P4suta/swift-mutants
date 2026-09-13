// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore

/// The wire format of a recording, written out by hand.
///
/// Synthesised coding would nest an enum's payload under a case name and choose the key
/// spellings from the Swift identifiers. The format here is flat, with a `kind`
/// discriminator, and its keys are the ones a reader greps for - `duration_ms`, `env_names`,
/// `stdout_sha256`. It is a contract with `trace diff`, with the JSON Schema beside it, and
/// with anybody reading a recording attached to a bug report, so it is spelled out rather
/// than inferred.
extension TraceEvent: Codable {

    private enum Key: String, CodingKey {
        case sequence = "seq"
        case kind
        case runIdentifier = "run_id"
        case toolVersion = "tool_version"
        case phase
        case durationMilliseconds = "duration_ms"
        case code
        case message
        case outcome
        case label
        case arguments = "argv"
        case directory = "dir"
        case environmentNames = "env_names"
        case timeoutMilliseconds = "timeout_ms"
        case exitCode = "exit"
        case standardOutputDigest = "stdout_sha256"
        case standardOutputBytes = "stdout_bytes"
        case failure
    }

    /// The `kind` discriminator each case writes.
    private enum Discriminator: String {
        case runStarted = "run-start"
        case phaseBegan = "phase-begin"
        case phaseEnded = "phase-end"
        case exec
        case warning
        case runEnded = "run-end"
    }

    /// Writes the event as one flat object with a `kind` discriminator.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(sequence, forKey: .sequence)
        switch kind {
        case .runStarted(let runIdentifier, let toolVersion):
            try container.encode(Discriminator.runStarted.rawValue, forKey: .kind)
            try container.encode(runIdentifier, forKey: .runIdentifier)
            try container.encode(toolVersion, forKey: .toolVersion)
        case .phaseBegan(let phase):
            try container.encode(Discriminator.phaseBegan.rawValue, forKey: .kind)
            try container.encode(phase, forKey: .phase)
        case .phaseEnded(let phase, let duration):
            try container.encode(Discriminator.phaseEnded.rawValue, forKey: .kind)
            try container.encode(phase, forKey: .phase)
            try container.encode(duration, forKey: .durationMilliseconds)
        case .exec(let execution):
            try container.encode(Discriminator.exec.rawValue, forKey: .kind)
            try container.encode(execution.label, forKey: .label)
            try container.encode(execution.arguments, forKey: .arguments)
            try container.encode(execution.directory, forKey: .directory)
            try container.encode(execution.environmentNames, forKey: .environmentNames)
            try container.encodeIfPresent(
                execution.timeoutMilliseconds, forKey: .timeoutMilliseconds)
            try container.encode(execution.exitCode, forKey: .exitCode)
            try container.encode(execution.durationMilliseconds, forKey: .durationMilliseconds)
            try container.encodeIfPresent(
                execution.standardOutputDigest, forKey: .standardOutputDigest)
            try container.encode(execution.standardOutputBytes, forKey: .standardOutputBytes)
            try container.encodeIfPresent(execution.failure, forKey: .failure)
        case .warning(let code, let message):
            try container.encode(Discriminator.warning.rawValue, forKey: .kind)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        case .runEnded(let outcome):
            try container.encode(Discriminator.runEnded.rawValue, forKey: .kind)
            try container.encode(outcome, forKey: .outcome)
        }
    }

    /// Reads one line of a recording, refusing a sequence number or a kind that no run
    /// could have written.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)

        let sequence = try container.decode(Int.self, forKey: .sequence)
        guard sequence >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .sequence,
                in: container,
                debugDescription:
                    "a sequence number is one-based and dense; \(sequence) cannot be one"
            )
        }

        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let discriminator = Discriminator(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription:
                    "'\(rawKind)' is not a kind this build records; a newer build may have written it"
            )
        }

        self.init(
            sequence: sequence,
            kind: try Self.decodeKind(discriminator, from: container)
        )
    }

    /// Reads the payload that goes with a discriminator.
    ///
    /// Split out of the initialiser because the whole wire format in one function is a
    /// function nobody reads to the end, and the one place a field can go missing is the
    /// place a reader most needs to be able to check.
    private static func decodeKind(
        _ discriminator: Discriminator,
        from container: KeyedDecodingContainer<Key>
    ) throws -> Kind {
        switch discriminator {
        case .runStarted:
            return .runStarted(
                runIdentifier: try container.decode(String.self, forKey: .runIdentifier),
                toolVersion: try container.decode(String.self, forKey: .toolVersion)
            )
        case .phaseBegan:
            return .phaseBegan(phase: try container.decode(String.self, forKey: .phase))
        case .phaseEnded:
            return .phaseEnded(
                phase: try container.decode(String.self, forKey: .phase),
                durationMilliseconds: try container.decode(Int.self, forKey: .durationMilliseconds)
            )
        case .exec:
            return .exec(try decodeExecution(from: container))
        case .warning:
            return .warning(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        case .runEnded:
            return .runEnded(outcome: try container.decode(String.self, forKey: .outcome))
        }
    }

    /// Reads one subprocess record.
    private static func decodeExecution(
        from container: KeyedDecodingContainer<Key>
    ) throws -> Execution {
        Execution(
            label: try container.decode(String.self, forKey: .label),
            arguments: try container.decode([String].self, forKey: .arguments),
            directory: try container.decode(String.self, forKey: .directory),
            environmentNames: try container.decode([String].self, forKey: .environmentNames),
            timeoutMilliseconds: try container.decodeIfPresent(
                Int.self,
                forKey: .timeoutMilliseconds
            ),
            exitCode: try container.decode(Int.self, forKey: .exitCode),
            durationMilliseconds: try container.decode(Int.self, forKey: .durationMilliseconds),
            standardOutputDigest: try container.decodeIfPresent(
                Digest.self,
                forKey: .standardOutputDigest
            ),
            standardOutputBytes: try container.decode(Int.self, forKey: .standardOutputBytes),
            failure: try container.decodeIfPresent(String.self, forKey: .failure)
        )
    }
}
