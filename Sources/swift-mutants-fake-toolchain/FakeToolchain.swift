// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit

/// A `swift` and an `xcodebuild` that answer from a rule table.
///
/// This exists so that the unit tier can test what swift-mutants does when a toolchain
/// misbehaves. A `swift build` that hangs cannot be installed; one that prints garbage for
/// `--version`, or refuses a package pattern, or leaves a red baseline behind, would each
/// otherwise be an integration test costing minutes and a real toolchain - or, more often,
/// no test at all.
///
/// It also gives the unit tier an assertion it could not otherwise make. The call log is
/// the argument vector, the working directory and the variables a child process *really*
/// received, so "the compile carries the instrumented tree's flags and the pristine
/// baseline does not" becomes a claim about a process rather than about a struct.
///
/// A call no rule matches exits 97 naming the argument vector. A test can therefore never
/// pass on a command nobody scripted.
@main
struct FakeToolchain {

    static func main() {
        let arguments = CommandLine.arguments
        let environment = ProcessInfo.processInfo.environment

        recordCall(arguments: arguments, environment: environment)

        guard let rule = matchingRule(for: arguments, environment: environment) else {
            FileHandle.standardError.write(
                Data(
                    """
                    swift-mutants-fake-toolchain: no rule matched \
                    \(arguments.joined(separator: " "))
                    Scripted commands are the only ones this answers, so that a test cannot \
                    pass on a command nobody wrote down.

                    """.utf8
                )
            )
            exit(FakeToolchainEnvironment.unscriptedExitCode)
        }

        if rule.delayMilliseconds > 0 {
            Thread.sleep(forTimeInterval: Double(rule.delayMilliseconds) / 1000)
        }
        for (path, contents) in rule.writes.sorted(by: { $0.key < $1.key }) {
            let url = URL(filePath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data(contents.utf8).write(to: url)
        }
        if !rule.standardOutput.isEmpty {
            FileHandle.standardOutput.write(Data(rule.standardOutput.utf8))
        }
        if !rule.standardError.isEmpty {
            FileHandle.standardError.write(Data(rule.standardError.utf8))
        }
        exit(rule.exitCode)
    }

    /// The first rule whose arguments appear, in order, in the call.
    private static func matchingRule(
        for arguments: [String],
        environment: [String: String]
    ) -> FakeToolchainRule? {
        guard let path = environment[FakeToolchainEnvironment.ruleTable],
            let data = FileManager.default.contents(atPath: path),
            let rules = try? JSONDecoder().decode([FakeToolchainRule].self, from: data)
        else {
            return nil
        }
        // argv[0] is the name the tool was invoked under, which is part of what a rule
        // matches: `swift` and `xcodebuild` are the same executable wearing two names.
        let invocation = ([URL(filePath: arguments[0]).lastPathComponent] + arguments.dropFirst())
        return rules.first { isSubsequence($0.whenArgumentsContain, of: invocation) }
    }

    /// Whether every wanted argument appears in order.
    private static func isSubsequence(_ wanted: [String], of actual: [String]) -> Bool {
        var remaining = actual[...]
        for argument in wanted {
            guard let position = remaining.firstIndex(of: argument) else { return false }
            remaining = remaining[remaining.index(after: position)...]
        }
        return true
    }

    /// Appends a record of the call, if a log was asked for.
    ///
    /// Appended rather than collected, and written before the rule is looked up, so that a
    /// call which matched nothing is still in the log: what a test most wants to see after
    /// an unscripted-command failure is the command.
    private static func recordCall(arguments: [String], environment: [String: String]) {
        guard let path = environment[FakeToolchainEnvironment.callLog] else { return }
        let call = FakeToolchainCall(
            arguments: arguments,
            directory: FileManager.default.currentDirectoryPath,
            environment: environment.filter {
                FakeToolchainEnvironment.recordedValues.contains($0.key)
            },
            environmentNames: environment.keys.sorted()
        )
        guard var line = try? JSONEncoder().encode(call) else { return }
        line.append(contentsOf: Data("\n".utf8))

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: URL(filePath: path))
        }
    }
}
