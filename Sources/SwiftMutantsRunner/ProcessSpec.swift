// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

package struct ProcessSpec: Sendable, Hashable {
    package enum Kind: String, Sendable, Hashable, CaseIterable {
        case versionProbe = "version-probe"
        case describe, build, baseline, mutant
        case testFixture = "test-fixture"
    }

    package let kind: Kind
    package let executable: String
    package let arguments: [String]
    package let directory: String
    package let environment: [String: String]
    package let timeout: Duration?

    package init(
        kind: Kind,
        executable: String,
        arguments: [String],
        directory: String,
        environment: [String: String],
        timeout: Duration?
    ) {
        self.kind = kind
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.timeout = timeout
    }

    package static func rendered(_ spec: Self, showing names: Set<String> = []) -> String {
        let variables = spec.environment
            .filter { $0.key.hasPrefix("SWIFT_MUTANTS") || names.contains($0.key) }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\(quoted($0.value))" }
        return (variables + [quoted(spec.executable)] + spec.arguments.map(quoted)).joined(
            separator: " "
        )
    }

    private static func quoted(_ word: String) -> String {
        let plain = word.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:,@+".contains($0) }
        guard !plain || word.isEmpty else { return word }
        return "'"
            + word.split(separator: "'", omittingEmptySubsequences: false)
            .joined(separator: #"'\\''"#) + "'"
    }
}

package struct ProcessOutcome: Sendable {
    package let exitCode: Int
    package let timedOut: Bool
    package let durationMilliseconds: Int
    package let standardOutput: [UInt8]
    package let standardOutputBytes: Int
    package var standardOutputWasCut: Bool { standardOutputBytes > standardOutput.count }
    package let standardError: [UInt8]
    package let startFailure: String?
    package let traceSequence: Int
    package var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    package var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}
