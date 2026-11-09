// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftOperators
import SwiftParser
import SwiftSyntax
public import SwiftMutantsCore

/// Finds what could be mutated in one file, and names what was passed over.
///
/// Discovery is where a run decides what it is about.
/// Everything downstream - the catalogue, the identities, the cache keys, the score - is a consequence of it, so a candidate invented here and a candidate silently dropped here are equally serious.
///
/// The tree is **folded** before it is walked.
/// `SwiftSyntax` parses `a && b || c` as a flat sequence with no precedence in it, so without folding there is no such thing as "the expression this operator belongs to" - and that expression is exactly what a guard has to wrap.
/// Folding preserves every byte position, so a span still names the bytes of the file the user wrote.
public enum Discover {

    /// Discovers mutations in the fixed nine families.
    public static func candidates(
        in source: String,
        at path: WorkspaceRelativePath
    ) -> FileDiscovery {
        let tree = Parser.parse(source: source)
        let folded = OperatorTable.standardOperators.foldAll(tree) { _ in }

        let suppressions = Suppressions(source: source)
        let walker = CandidateWalker(
            locations: SourceLocationConverter(fileName: "<source>", tree: folded),
            suppressions: suppressions,
            skipsStatements: true
        )
        walker.walk(folded)

        // What can be put on one line, and where the comments are that have to come out of it first.
        // Both are facts about the tree rather than about the bytes, and both have to be known here: `list` prints this catalogue and a run instruments it, so a site neither of them can place must be passed over in the one place they share.
        let scan = SourceScan(folded)

        let wanted = Self.distinct(walker.candidates).filter {
            Rules.familyOfRule[$0.rule.name].map(RuleSelection.families.contains) == true
        }
        let offered = Self.flattenable(wanted, by: scan)

        return FileDiscovery(
            path: path,
            sourceDigest: Digest.of(source),
            candidates: offered.candidates.sorted { $0.span < $1.span },
            skips: (walker.skips + offered.skips)
                .sorted { $0.span < $1.span },
            unknownSuppressions: suppressions.unknownFamilies
                .map { UnknownSuppression(line: $0.line, name: $0.name) }
                .sorted { ($0.line, $0.name) < ($1.line, $1.name) },
            lineComments: scan.lineComments
        )
    }

    /// One candidate per edit.
    ///
    /// Two rules can arrive at the same bytes.
    /// `for x in xs where true` is a boolean literal *and* a pattern's condition, so the literal rule and the pattern rule both offer `false` over the same span - two entries in the catalogue, two processes, two lines in the report, and one question.
    ///
    /// The winner is the rule whose name sorts first, which is arbitrary and deterministic.
    /// Arbitrary is the honest word: with identical spans there is no sense in which one rule is more local than the other, and a rule that claimed to prefer the "more specific" one would be inventing a hierarchy to justify a coin toss.
    /// Deterministic is the part that matters, because a mutant's identity is its rule, and a catalogue that named this one differently on Tuesday would invalidate every cached answer about it.
    ///
    /// Left where it is in the order, so the sort below still puts the file in file order.
    private static func distinct(_ candidates: [Candidate]) -> [Candidate] {
        var best: [Edit: Candidate] = [:]
        for candidate in candidates {
            let edit = Edit(span: candidate.span, replacement: candidate.replacement)
            if let taken = best[edit], taken.rule.name <= candidate.rule.name { continue }
            best[edit] = candidate
        }
        let kept = Set(best.values.map { Edit(span: $0.span, rule: $0.rule.name) })
        return candidates.filter {
            kept.contains(Edit(span: $0.span, rule: $0.rule.name))
        }
    }

    /// One edit, as the pair that decides whether two candidates are the same question.
    private struct Edit: Hashable {
        var span: SourceSpan
        var replacement: String = ""
        var rule: String = ""
    }

    /// The candidates whose site can be put on one line, and a named skip for each that cannot.
    ///
    /// Multiline string contents must retain their newlines.
    /// Line comments can be omitted from the mutated copy while the original retains them.
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
        // One skip per site rather than one per candidate: the site is what could not be put on a line, and the count is how many mutants that cost.
        return (
            offered,
            passed.keys.sorted().map {
                Skip(reason: .multilineString, span: $0, candidatesHidden: passed[$0] ?? 0)
            }
        )
    }
}
