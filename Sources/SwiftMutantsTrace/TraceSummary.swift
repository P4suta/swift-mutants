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

    /// Renders command summaries with counts, duration shares, and failed execution counts.
    public static func lines(of events: [TraceEvent]) -> [String] {
        let rows = Self.of(events)
        guard !rows.isEmpty else { return ["this run started nothing."] }
        let total = rows.reduce(0) { $0 + $1.milliseconds }
        return rows.map { row in
            let share = total > 0 ? row.milliseconds * 100 / total : 0
            return "  \(Self.padded(row.label))  \(Self.seconds(row.milliseconds))  "
                + "\(share)%  \(row.count) run\(row.count == 1 ? "" : "s")"
                + (row.failed > 0 ? ", \(row.failed) of them failed" : "")
        }
    }

    private static func padded(_ label: String) -> String {
        label.count >= 14 ? label : label + String(repeating: " ", count: 14 - label.count)
    }

    private static func seconds(_ milliseconds: Int) -> String {
        guard milliseconds >= 60_000 else { return "\(milliseconds / 1000)s" }
        return "\(milliseconds / 60_000)m\((milliseconds % 60_000) / 1000)s"
    }
}
