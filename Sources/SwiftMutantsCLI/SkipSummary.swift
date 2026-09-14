// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover

/// What was passed over, gathered by reason rather than scattered by place.
///
/// `list --explain` prints every skip where it is, which is what somebody wants when they
/// are looking at one file. It is not what they want when they are asking a different
/// question - "is this tool ignoring half my package, and on what grounds?" - and that
/// question is the one that decides whether a score means anything at all.
///
/// A tool that suppresses a thousand mutants and never says so is a tool reporting a score
/// about a program it chose. This is where that choice is shown.
enum SkipSummary {

    /// One line per reason, busiest first.
    ///
    /// Every reason there is, including the ones that hid nothing. A reason nobody has met
    /// is a reason nobody can judge, and a zero beside one is how somebody learns it exists
    /// at all - which is the point at which they can disagree with it.
    static func lines(for skips: [(path: WorkspaceRelativePath, skip: Skip)]) -> [String] {
        var places: [SkipReason: Int] = [:]
        var hidden: [SkipReason: Int] = [:]
        for (_, skip) in skips {
            places[skip.reason, default: 0] += 1
            hidden[skip.reason, default: 0] += skip.candidatesHidden
        }

        let rows = SkipReason.allCases
            .sorted { (hidden[$0] ?? 0, $1.rawValue) > (hidden[$1] ?? 0, $0.rawValue) }
            .map { reason in
                "  \(reason.rawValue)  \(places[reason] ?? 0) places  \(hidden[reason] ?? 0) mutants"
            }
        guard !skips.isEmpty else {
            return ["nothing was passed over."] + rows
        }
        let total = hidden.values.reduce(0, +)
        return ["\(skips.count) places passed over, hiding \(total) mutants:"] + rows
    }
}
