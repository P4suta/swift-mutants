// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore

/// A mutant a project wrote for itself, as discovery needs it.
///
/// The configuration's row without the file, because by the time discovery has one it is
/// already reading that file. A shape of its own rather than the configuration's, so that
/// discovery does not depend on how a project happens to be configured - the same reason
/// the pure core does not know what a TOML file is.
public struct CustomMutant: Sendable, Hashable {

    /// The exact text to replace.
    public let find: String

    /// What to put there instead. May be empty: deleting a call is a mutation.
    public let replace: String

    /// What the mutant is asking, in the project's own words.
    ///
    /// Carried because it is what a message about a stale anchor has to say. "hold frames
    /// until the memory runs out" tells somebody instantly what moved and what to re-anchor
    /// it to; a span or a digest tells them nothing.
    public let reason: String

    /// Which line to look on, when the text appears more than once.
    public let line: Int?

    /// Describes one.
    public init(find: String, replace: String, reason: String, line: Int? = nil) {
        self.find = find
        self.replace = replace
        self.reason = reason
        self.line = line
    }
}

/// A project's own mutant that had nothing to anchor to.
///
/// The row and how many times its anchor was found, which together are everything somebody
/// needs: the count says whether the code moved or the anchor is too short - different
/// fixes - and the row says which of theirs it was, in their own words.
public struct UnanchoredMutant: Sendable, Hashable {

    /// The row, as the project wrote it.
    public let row: CustomMutant

    /// How many times its anchor was in the file. Never one; one is a mutant.
    public let occurrences: Int

    /// Records a row that could not be placed.
    public init(row: CustomMutant, occurrences: Int) {
        self.row = row
        self.occurrences = occurrences
    }
}

extension Discover {

    /// The rule every one of a project's own mutants is filed under.
    ///
    /// One name for all of them, because what distinguishes two is where they are and what
    /// they do - both of which are already in a mutant's identity. A rule per row would put
    /// a project's private vocabulary into a field the report promises to keep stable.
    static let customRule = "custom"

    /// Where each row's anchor is in this file, or the reason it is nowhere usable.
    ///
    /// Exactly one occurrence, and the two ways that fails want completely different fixes:
    /// more than one is a too-short anchor, none is code that moved. Both are said, with
    /// the count, because the count is what tells them apart.
    ///
    /// Never "all the matches". A row that silently became forty mutants is a project
    /// measuring something it did not write down, and the score would move for a reason
    /// nobody could find.
    static func anchored(
        _ rows: [CustomMutant], in source: String, lines: LineIndex
    ) -> Anchoring {
        let bytes = Array(source.utf8)
        var candidates: [Candidate] = []
        var skips: [Skip] = []
        var unanchored: [UnanchoredMutant] = []

        for row in rows {
            let places = Self.occurrences(of: row.find, in: bytes)
                .filter { start in
                    guard let wanted = row.line else { return true }
                    return lines.position(of: start)?.line == wanted
                }
            guard places.count == 1, let start = places.first,
                let span = SourceSpan(start: start, end: start + row.find.utf8.count)
            else {
                skips.append(Self.missing(found: places.count))
                unanchored.append(UnanchoredMutant(row: row, occurrences: places.count))
                continue
            }
            candidates.append(
                Candidate(
                    rule: Rules.identifier(named: Self.customRule),
                    span: span,
                    original: row.find,
                    replacement: row.replace,
                    guardSpan: span,
                    enclosingDeclaration: ""
                )
            )
        }
        return Anchoring(candidates: candidates, skips: skips, unanchored: unanchored)
    }

    /// What a file's worth of a project's own rows came to.
    ///
    /// A value rather than three lists loose, because they are three answers to one
    /// question and a caller taking two of them would be a caller quietly dropping the
    /// third - which here means a row that stopped applying going unsaid.
    struct Anchoring {
        let candidates: [Candidate]
        let skips: [Skip]
        let unanchored: [UnanchoredMutant]
    }

    /// A row whose anchor is nowhere usable, as a skip.
    ///
    /// The span is the start of the file, because there is no place to point at - that is
    /// the whole problem. Which row it was is not here either: a skip carries a reason and
    /// a place, and the row's own words belong to whatever narrates it. Somebody who had
    /// done this by hand for 290 rows reported that naming the row by its description was
    /// the difference between a two-minute fix and a hunt, so that is a thing the narration
    /// owes them and not something this can supply from one file.
    private static func missing(found: Int) -> Skip {
        guard let nowhere = SourceSpan(start: 0, end: 0) else {
            fatalError("an empty span at the start of a file is a span")
        }
        return Skip(
            reason: found == 0 ? .customAnchorNotFound : .customAnchorNotUnique,
            span: nowhere,
            candidatesHidden: 1
        )
    }

    /// Where a string starts in these bytes, every time it does.
    ///
    /// Bytes rather than characters, because a span is bytes everywhere else in this tool
    /// and a mutant anchored by character offsets would move the moment somebody put an
    /// accent above it.
    static func occurrences(of text: String, in bytes: [UInt8]) -> [Int] {
        let needle = Array(text.utf8)
        guard !needle.isEmpty, needle.count <= bytes.count else { return [] }
        var found: [Int] = []
        for start in 0...(bytes.count - needle.count)
        where Array(bytes[start..<(start + needle.count)]) == needle {
            found.append(start)
        }
        return found
    }
}
