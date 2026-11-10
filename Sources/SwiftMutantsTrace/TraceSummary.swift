// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Aggregates command counts, failures, and durations from recorded executions.
public enum TraceSummary {

    /// One kind of command, and what it came to.
    public struct Row: Sendable, Hashable {

        /// What the commands were.
        public let label: String

        /// How many there were.
        public let count: Int

        /// The number of executions with a nonzero exit code.
        public let failed: Int

        /// What they came to, added up.
        public let milliseconds: Int

        /// Records one kind.
        public init(label: String, count: Int, failed: Int, milliseconds: Int) {
            self.label = label
            self.count = count
            self.failed = failed
            self.milliseconds = milliseconds
        }
    }

    /// Groups executions by label and orders them by decreasing total duration.
    /// Equal durations are ordered by label.
    public static func of(_ events: [TraceEvent]) -> [Row] {
        var totals: [String: Row] = [:]
        for event in events {
            guard case .exec(let execution) = event.kind else { continue }
            let sofar = totals[execution.label]
            totals[execution.label] = Row(
                label: execution.label,
                count: (sofar?.count ?? 0) + 1,
                failed: (sofar?.failed ?? 0) + (execution.exitCode == 0 ? 0 : 1),
                milliseconds: (sofar?.milliseconds ?? 0) + execution.durationMilliseconds
            )
        }
        return totals.values.sorted { ($0.milliseconds, $1.label) > ($1.milliseconds, $0.label) }
    }
}
