// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover

/// Explaining two sites no splice order can satisfy.
///
/// Its own file because the explanation is longer than the refusal and is the whole
/// value of it: "somewhere in this file" leaves a reader grepping a catalogue for a
/// filename, which is what somebody did, and it worked only because they already
/// suspected their own rows.
extension Instrument {

    /// The two sites, in the words somebody can act on.
    ///
    /// A span and, where one is a mutant this tool generated or a row somebody wrote, what
    /// it is about. A project's own rows are the reachable cause - an anchor that begins or
    /// ends part-way through a node is neither inside the site there nor outside it - so
    /// saying which of the two is a row is most of the fix.
    static func naming(
        _ conflict: IntervalForest<[Candidate]>.Conflict?, in discovery: FileDiscovery
    ) -> String {
        guard let conflict else {
            // The forest refused and then could not say why, which is this tool
            // disagreeing with itself rather than anything about the file.
            return "The two could not be named, which is a defect in this tool."
        }
        return """
            The sites are \(Self.describing(conflict.earlier, in: discovery)) and \
            \(Self.describing(conflict.later, in: discovery)). If either is one of your own \
            `[[mutation.custom]]` rows, its `find` covers bytes the expression does not - \
            anchor it on the expression alone.
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
