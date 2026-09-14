// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsTrace

/// Turns the recorded account of a run into lines a person reads.
///
/// A pure function from values to strings, with nothing here that can write to a terminal.
///
/// Only the account. What a run *found* is rendered in one place - `Narration` - and that
/// is the point rather than an accident: a run on a real terminal draws while it works and
/// then leaves the same closing block a pipe would have received, and the way to guarantee
/// that is for there to be one function that formats it. This renders the other stream, the
/// one `-vv` asks for, which has no second implementation to agree with.
public struct ConsoleRenderer: Sendable {

    /// How much this renderer says.
    public let verbosity: Verbosity

    /// Creates a renderer.
    ///
    /// It says nothing about colour. Every line it produces is what a golden file can hold
    /// and what a CI log can be diffed as, and a flag nothing consulted was a promise of
    /// something else.
    public init(verbosity: Verbosity) {
        self.verbosity = verbosity
    }

    /// One recorded event, or nothing below the level that asked for it.
    ///
    /// Indented by exactly two spaces. Two streams share one output and are separated by
    /// shape rather than by being interleaved carefully: `grep '^  '` is the account and
    /// `grep -v '^  '` is the run without it. Where the recorded lines fall among the run's
    /// own is up to scheduling, because they arrive through a forwarder that never makes the
    /// run wait for a terminal.
    public func trace(_ event: TraceEvent) -> String? {
        guard verbosity >= .veryVerbose else { return nil }
        return "  " + Self.body(of: event)
    }

    private static func body(of event: TraceEvent) -> String {
        switch event.kind {
        case .runStarted(let runIdentifier, let toolVersion):
            return "run-start \(runIdentifier) \(toolVersion)"
        case .phaseBegan(let phase):
            return "phase-begin \(phase)"
        case .phaseEnded(let phase, let duration):
            return "phase-end \(phase) \(duration)ms"
        case .exec(let execution):
            // One line however wide: an argument vector is meant to be selected and pasted
            // back into a shell, so it is never wrapped.
            var line =
                "exec \(execution.label) exit \(execution.exitCode)"
                + " \(execution.durationMilliseconds)ms \(execution.arguments.joined(separator: " "))"
            if let failure = execution.failure {
                line += " (\(failure))"
            }
            return line
        case .warning(let code, let message):
            return "warning \(code) \(message)"
        case .runEnded(let outcome):
            return "run-end \(outcome)"
        }
    }
}
