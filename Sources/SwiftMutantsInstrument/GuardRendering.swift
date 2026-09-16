// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
internal import SwiftMutantsDiscover

/// Turning one site of the forest into text.
///
/// Apart from the file-level work because this is where the two shapes of guard are decided
/// between and where every byte offset is kept honest: the rest of instrumenting a file is
/// reading it, numbering what was found, and writing the result out. A span that comes back
/// from here is relative to the text it came with, and the arithmetic that keeps it that
/// way is the whole of what these functions do.
extension Instrument {

    /// Renders one site: its mutants as alternatives, its children inside the original side.
    ///
    /// The recursion runs innermost-first through the forest, so a child is rendered before
    /// the bytes around it move.
    static func render(
        _ node: IntervalForest<[Candidate]>.Node,
        bytes: [UInt8],
        token: String,
        indices: [SourceSpan: [UInt32]],
        comments: [SourceSpan]
    ) -> Rendered {
        // The original side keeps its bytes, with any nested guards spliced into it.
        let inner = Self.originalSide(
            node, bytes: bytes, token: token, indices: indices, comments: comments)
        let original = inner.text
        var placements = inner.placements
        var sites = inner.sites

        // One site can hold guards of both shapes, and the order they go in is not a
        // preference. `n += 1` is a statement *and* an expression, so the operator swap and
        // the statement skip land on exactly the same bytes - and rendering them both as
        // whichever came first produced text no compiler would take. Expression guards go
        // innermost, because a ternary needs an expression and what a statement guard
        // leaves behind is a statement.
        //
        // Zipped rather than looked up: numbering walked this same list in this same order,
        // so position is the join. A length mismatch drops a mutant here, and the placement
        // check then refuses the file rather than shipping a phantom.
        let everyAlternative = Array(zip(node.values.flatMap { $0 }, indices[node.span] ?? []))
        let alternatives = everyAlternative.filter { $0.0.form == .expression }
        let outer = everyAlternative.filter { $0.0.form != .expression }

        // The mutated sides carry the pristine expression with one edit applied, because
        // only one mutant is ever awake and a nested guard in here would never fire.
        //
        // Parenthesised only when something is going to wrap it in a ternary: a statement
        // in brackets is not a statement.
        var rendered = alternatives.isEmpty ? original : "(\(original))"
        if !alternatives.isEmpty {
            // The children just placed sit one byte in, past the opening parenthesis.
            placements = placements.compactMapValues { $0.shifted(by: 1) }
            sites = sites.compactMapValues { $0.shifted(by: 1) }
        }

        for (candidate, index) in alternatives.reversed() {
            let mutated = Self.apply(
                candidate, to: bytes, within: node.span, hiding: comments)
            let head = "(\(Runtime.guardCall(token: token, index: index)) ? ("
            rendered = "\(head)\(mutated)) : \(rendered))"

            // Everything already rendered moved right by this guard's head, its mutated
            // copy, and the `) : ` that separates the two sides.
            let shift = head.utf8.count + mutated.utf8.count + 4
            placements = placements.compactMapValues { $0.shifted(by: shift) }
            sites = sites.compactMapValues { $0.shifted(by: shift) }
            placements[index] = SourceSpan(
                start: head.utf8.count, end: head.utf8.count + mutated.utf8.count)
        }

        // Every mutant at this node belongs to the whole of what was just rendered.
        for (_, index) in alternatives {
            sites[index] = SourceSpan(start: 0, end: rendered.utf8.count)
        }
        guard !outer.isEmpty else {
            return Rendered(text: rendered, placements: placements, sites: sites)
        }
        return Self.statementGuarded(
            outer,
            around: rendered,
            token: token,
            placements: placements,
            sites: sites)
    }

    /// This site's own bytes, with every nested guard already spliced into them.
    ///
    /// Innermost-first: a child is rendered, and what it produced is offset by however much
    /// text was written before it. The spans that come back are relative to the start of
    /// the text, so the caller can shift the whole lot again when it wraps this in a guard
    /// of its own without knowing anything about where the children were.
    static func originalSide(
        _ node: IntervalForest<[Candidate]>.Node,
        bytes: [UInt8],
        token: String,
        indices: [SourceSpan: [UInt32]],
        comments: [SourceSpan]
    ) -> Rendered {
        var original = ""
        var produced = 0
        var placements: [UInt32: SourceSpan] = [:]
        var sites: [UInt32: SourceSpan] = [:]
        var cursor = node.span.start
        for child in node.children {
            let lead = String(decoding: bytes[cursor..<child.span.start], as: UTF8.self)
            original += lead
            produced += lead.utf8.count

            let rendered = Self.render(
                child, bytes: bytes, token: token, indices: indices, comments: comments)
            original += rendered.text
            for (index, relative) in rendered.placements {
                placements[index] = relative.shifted(by: produced)
            }
            for (index, relative) in rendered.sites {
                sites[index] = relative.shifted(by: produced)
            }
            produced += rendered.text.utf8.count
            cursor = child.span.end
        }
        original += String(decoding: bytes[cursor..<node.span.end], as: UTF8.self)
        return Rendered(text: original, placements: placements, sites: sites)
    }

    /// A body with its guards put in front of it.
    ///
    /// `{ if g { return x } <body> }`, on the brace's own line. Nothing of the body moves,
    /// so every line number in the file is what it was - which is what the coverage a run
    /// reads back afterwards rests on, and the one property this shape exists to keep.
    ///
    /// The guards go in reverse so the first mutant ends up leftmost, which is only a
    /// matter of reading: one mutant is ever awake, so two guards in front of a body are
    /// two conditions of which at most one is true.
    static func statementGuarded(
        _ alternatives: [(Candidate, UInt32)],
        around original: String,
        token: String,
        placements: [UInt32: SourceSpan],
        sites: [UInt32: SourceSpan]
    ) -> Rendered {
        var rendered = original
        var placements = placements
        var sites = sites
        for (candidate, index) in alternatives.reversed() {
            // A body's guard goes *in front of* what is there and does its work when the
            // mutant is awake. A statement's guard goes *around* it and does its work when
            // the mutant is asleep - the mutation being that the statement does not run, so
            // the condition has to be the other way up.
            let awake = Runtime.guardCall(token: token, index: index)
            let head =
                candidate.form == .skipping ? " if !\(awake) { " : " if \(awake) { "
            let body = candidate.form == .skipping ? "" : candidate.replacement
            let guarded = candidate.form == .skipping ? "\(head)" : "\(head)\(body) }"
            // Around, not in front: the original keeps every byte and every newline it had,
            // and only its first and last lines gain any text.
            rendered = candidate.form == .skipping ? guarded + rendered + " }" : guarded + rendered

            let shift = guarded.utf8.count
            placements = placements.compactMapValues { $0.shifted(by: shift) }
            sites = sites.compactMapValues { $0.shifted(by: shift) }
            placements[index] = SourceSpan(
                start: head.utf8.count, end: head.utf8.count + body.utf8.count)
        }
        for (_, index) in alternatives {
            sites[index] = SourceSpan(start: 0, end: rendered.utf8.count)
        }
        return Rendered(text: rendered, placements: placements, sites: sites)
    }

    /// One site's text, and where inside it each mutant's copy of the expression landed.
    struct Rendered {
        var text: String
        /// Byte spans of each mutant's own copy, relative to the start of ``text``.
        var placements: [UInt32: SourceSpan]
        /// Byte spans of the whole guard each mutant belongs to, relative the same way.
        var sites: [UInt32: SourceSpan]
    }
}
