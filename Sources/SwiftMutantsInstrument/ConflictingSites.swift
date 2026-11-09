// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover

/// Names the source spans of mutation sites that overlap without containment.
extension Instrument {

    /// Describes both conflicting sites and their mutation rules.
    static func naming(
        _ conflict: IntervalForest<[Candidate]>.Conflict?, in discovery: FileDiscovery
    ) -> String {
        guard let conflict else {
            // The forest refused and then could not say why, which is this tool disagreeing with itself rather than anything about the file.
            return "The two could not be named, which is a defect in this tool."
        }
        return """
            The sites are \(Self.describing(conflict.earlier, in: discovery)) and \
            \(Self.describing(conflict.later, in: discovery)).
            """
    }

    /// One site, as bytes and as whatever is there.
    private static func describing(
        _ span: SourceSpan, in discovery: FileDiscovery
    ) -> String {
        let here = discovery.candidates.filter { $0.guardSpan == span }
        let rules = Set(here.map(\.rule.name)).sorted().joined(separator: ", ")
        guard let original = here.first?.original else {
            return "bytes \(span.start)..<\(span.end)"
        }
        return "bytes \(span.start)..<\(span.end) (\(rules)) over `\(original)`"
    }
}
