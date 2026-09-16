// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsConfig
import SwiftOperators
import SwiftParser
import SwiftSyntax
public import SwiftMutantsCore

/// Finds what could be mutated in one file, and names what was passed over.
///
/// Discovery is where a run decides what it is about. Everything downstream - the
/// catalogue, the identities, the cache keys, the score - is a consequence of it, so a
/// candidate invented here and a candidate silently dropped here are equally serious.
///
/// The tree is **folded** before it is walked. `SwiftSyntax` parses `a && b || c` as a flat
/// sequence with no precedence in it, so without folding there is no such thing as "the
/// expression this operator belongs to" - and that expression is exactly what a guard has
/// to wrap. Folding preserves every byte position, so a span still names the bytes of the
/// file the user wrote.
public enum Discover {

    /// Reads one file.
    /// `custom` are the mutants this project wrote for itself that name this file. They
    /// sit beside the generated ones rather than instead of them, because they ask a
    /// different question: the catalogue asks whether an operator is correct, and a
    /// project's own usually asks whether a piece of it is load-bearing.
    /// `selecting` is which of the rules this build knows about the run asked for, from
    /// `profile` and `operators`. Defaults to all of them, so a caller with no settings in
    /// hand - `list` on a package with no configuration file, a test about one rule - gets
    /// the whole catalogue rather than a tier it did not choose.
    public static func candidates(
        in source: String,
        at path: WorkspaceRelativePath,
        custom: [CustomMutant] = [],
        selecting mutation: Configuration.Mutation? = nil
    ) -> FileDiscovery {
        let tree = Parser.parse(source: source)
        let folded = OperatorTable.standardOperators.foldAll(tree) { _ in }

        let suppressions = Suppressions(source: source)
        let walker = CandidateWalker(
            locations: SourceLocationConverter(fileName: "<source>", tree: folded),
            suppressions: suppressions
        )
        walker.walk(folded)

        let own = Self.anchored(custom, in: source, lines: LineIndex(source))

        // What can be put on one line, and where the comments are that have to come out of
        // it first. Both are facts about the tree rather than about the bytes, and both
        // have to be known here: `list` prints this catalogue and a run instruments it, so
        // a site neither of them can place must be passed over in the one place they share.
        let scan = SourceScan(folded)

        // Narrowed before flattening, because a rule the run did not ask for should not be
        // reported as a site that could not be put on one line. Two true statements about
        // the same candidate, and the one a reader can act on is the one they chose.
        //
        // A project's own mutants are never narrowed: `profile` is about the catalogue this
        // tool generates, and somebody who wrote a mutation down by hand has already said
        // they want it.
        let selection = mutation.map(RuleSelection.init) ?? .everything
        let wanted = Self.selected(walker.candidates, by: selection)
        let offered = Self.flattenable(wanted.candidates + own.candidates, by: scan)

        return FileDiscovery(
            path: path,
            sourceDigest: Digest.of(source),
            candidates: offered.candidates.sorted { $0.span < $1.span },
            skips: (walker.skips + own.skips + wanted.skips + offered.skips)
                .sorted { $0.span < $1.span },
            unknownSuppressions: suppressions.unknownFamilies
                .map { UnknownSuppression(line: $0.line, name: $0.name) }
                .sorted { ($0.line, $0.name) < ($1.line, $1.name) },
            unanchored: own.unanchored,
            lineComments: scan.lineComments
        )
    }

    /// The candidates the run asked for, and a named skip for each it did not.
    ///
    /// One skip per site rather than one per candidate, for the same reason flattening does
    /// it that way: the site is the thing in the file, and the count is what the setting
    /// cost there. A rule this build does not know the family of is offered rather than
    /// narrowed away - a `profile` that has never heard of a new operator must not be the
    /// thing that silently removes it.
    private static func selected(
        _ candidates: [Candidate], by selection: RuleSelection
    ) -> (candidates: [Candidate], skips: [Skip]) {
        var offered: [Candidate] = []
        var passed: [SourceSpan: (reason: SkipReason, count: Int)] = [:]
        for candidate in candidates {
            guard let family = Rules.familyOfRule[candidate.rule.name],
                let reason = selection.verdict(rule: candidate.rule.name, family: family)
            else {
                offered.append(candidate)
                continue
            }
            let seen = passed[candidate.guardSpan]
            passed[candidate.guardSpan] = (seen?.reason ?? reason, (seen?.count ?? 0) + 1)
        }
        return (
            offered,
            passed.keys.sorted().compactMap { span in
                passed[span].map {
                    Skip(reason: $0.reason, span: span, candidatesHidden: $0.count)
                }
            }
        )
    }

    /// The candidates whose site can be put on one line, and a named skip for each that
    /// cannot.
    ///
    /// One shape cannot: a site holding a string whose newlines are part of what it means.
    /// A line comment can, because the mutated copy does without it, so this is a much
    /// narrower thing than the refusal it replaced - narrow enough to be a skip somebody
    /// reads in `list --explain` rather than a run that stops.
    private static func flattenable(
        _ candidates: [Candidate], by scan: SourceScan
    ) -> (candidates: [Candidate], skips: [Skip]) {
        guard !scan.multilineStrings.isEmpty else { return (candidates, []) }

        var offered: [Candidate] = []
        var passed: [SourceSpan: Int] = [:]
        for candidate in candidates {
            guard scan.holdsAMultilineString(candidate.guardSpan) else {
                offered.append(candidate)
                continue
            }
            passed[candidate.guardSpan, default: 0] += 1
        }
        // One skip per site rather than one per candidate: the site is what could not be
        // put on a line, and the count is how many mutants that cost.
        return (
            offered,
            passed.keys.sorted().map {
                Skip(reason: .multilineString, span: $0, candidatesHidden: passed[$0] ?? 0)
            }
        )
    }
}
