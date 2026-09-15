// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Where a run's time went, out of what it already recorded.
///
/// A mutation run takes long enough that "it was slow" is the most common thing anybody has
/// to say about one, and there was no way to answer it. Every subprocess was already
/// recorded with what it cost - the recording is a choke point callers cannot forget - and
/// nothing read it back.
///
/// By what the commands were rather than by phase. The phases are already printed as they
/// happen; the question left over is which *kind* of work the time went into, and the two
/// answers that matter want opposite responses. A run that is mostly compiles wants fewer
/// rounds - better attribution, fewer halvings. A run that is mostly trials wants better
/// coverage, or a wider machine.
///
/// Durations and never timestamps, like everything else here. Two runs of the same package
/// should differ only where they did different work, and a summary carrying a clock could
/// not be diffed against yesterday's.
public enum TraceSummary {

    /// One kind of command, and what it came to.
    public struct Row: Sendable, Hashable {

        /// What the commands were.
        public let label: String

        /// How many there were.
        public let count: Int

        /// How many of them failed.
        ///
        /// Said because a hundred trials of which ninety failed is a different run from a
        /// hundred of which none did, and the time alone does not tell them apart.
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

    /// What a run's recorded commands came to, the longest kind first.
    ///
    /// The biggest first, because the first line is the answer for most people. Ties broken
    /// by name, so two runs of the same package order them the same way.
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

    /// The same, as lines somebody reads.
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

    /// A duration as somebody would say it, never as a clock.
    private static func seconds(_ milliseconds: Int) -> String {
        guard milliseconds >= 60_000 else { return "\(milliseconds / 1000)s" }
        return "\(milliseconds / 60_000)m\((milliseconds % 60_000) / 1000)s"
    }
}
