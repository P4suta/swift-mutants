// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore
public import SwiftMutantsTrace

/// Turns what a run knows into the lines a person reads.
///
/// A pure function from values to strings, with nothing here that can write to a terminal.
/// That is what lets the live dashboard and the plain output agree rather than merely
/// resemble each other: a run on a real terminal draws while it works, and then replays its
/// closing summary through *this* renderer instead of formatting its own, so the block left
/// in the scrollback is byte-identical to the one a pipe would have received.
public struct ConsoleRenderer: Sendable {

    /// How much a run says.
    ///
    /// Additive: each level prints everything the level below it does, and more. `-vv` is
    /// the recorded account printed as it happens - the same events `--trace` writes, sent
    /// through the console the run is already using.
    public enum Verbosity: Int, Sendable, Comparable, CaseIterable {
        /// Errors only.
        case quiet
        /// Phases, results and the closing summary.
        case normal
        /// Adds phase durations, what killed each mutant, and what covers a survivor.
        case verbose
        /// Adds one line per recorded event.
        case veryVerbose

        /// Orders by how much is said.
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How much this renderer says.
    public let verbosity: Verbosity

    /// Whether the output is going somewhere that can show colour.
    ///
    /// A property of the destination, never of what is being said. With it off the bytes
    /// are what a golden file can hold and what a CI log can be diffed as.
    public let color: Bool

    /// Creates a renderer.
    public init(verbosity: Verbosity, color: Bool) {
        self.verbosity = verbosity
        self.color = color
    }

    /// The closing block: the counters, the score, and how the run ended.
    ///
    /// Empty under ``Verbosity/quiet``, which is what "only errors" means.
    ///
    /// A column appears only where it means something. In a run without coverage guidance
    /// there is no such thing as an uncovered mutant, so a `uncovered 0` would read as a
    /// finding rather than as an absence; the same holds for the cache.
    public func summary(
        _ summary: RunSummary,
        runIdentifier: String,
        exitCode: Int,
        coverageGuided: Bool,
        cacheConsulted: Bool
    ) -> [String] {
        guard verbosity > .quiet else { return [] }

        var columns = [
            "mutants \(summary.total)",
            "killed \(summary.killed)",
            "survived \(summary.survived)",
            "timeout \(summary.timedOut)",
            "inconclusive \(summary.inconclusive)",
            "errored \(summary.errored)",
            "not-run \(summary.notRun)",
            "rejected \(summary.rejected)",
            "equivalent \(summary.equivalent)",
        ]
        if coverageGuided {
            columns.append("uncovered \(summary.uncovered)")
        }
        if cacheConsulted {
            columns.append("cached \(summary.cached)")
        }

        return [
            columns.joined(separator: "  "),
            "score \(summary.score.rendered)  covered \(summary.score.renderedForCoveredCode)",
            "run \(runIdentifier)  exit \(exitCode)",
        ]
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
