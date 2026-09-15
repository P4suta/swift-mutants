// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
public import SwiftMutantsDiscover

/// Puts every mutant of a file into that file at once, each behind a runtime guard.
///
/// This is the reason the tool is usable. Swift builds are slow, and a run that rebuilt
/// once per mutant would be an overnight job on a package of any size - Muter's open issues
/// about memory exhaustion and hour-long runs are what that looks like in practice. Here
/// the toolchain builds once and one environment variable decides which mutant is awake.
///
/// Three properties are load-bearing and each is held by a test.
///
/// **The line count does not change.** Every guard is an expression, the original side of
/// it keeps its bytes verbatim, and the mutated side is flattened onto one line. A coverage
/// profile taken from the instrumented build can therefore be read against the file the
/// user wrote, line for line.
///
/// **Only one mutant is ever awake**, so the mutated side of an outer guard carries the
/// pristine inner expression rather than a copy of the inner guard. That keeps the file
/// growing with the size of the rewritten expressions rather than with the number of
/// mutants times the size of the file.
///
/// **Every mutant leaves a marker.** A mutant whose marker cannot be found in the built
/// binary was never spliced in, and a run that assumed otherwise is what produced four
/// hundred false regressions in Muter.
public enum Instrument {

    /// Instruments one file from what discovery found in it.
    /// `base` is the number this file's first mutant takes, and
    /// ``InstrumentedFile/nextIndex`` is where the file after it starts.
    ///
    /// Numbering runs through a whole run rather than restarting per file, because every
    /// instrumented file reads the same `SWIFT_MUTANTS_ACTIVE`. Numbering each from zero
    /// meant one value woke the same index in all of them: measured on this repository,
    /// fifty-nine files, so asking for mutant 3 woke up to fifty-nine at once - and what a
    /// run learned from wrecking a program fifty-nine ways it reported as a fact about
    /// one of them.
    public static func file(
        _ source: String,
        discovery: FileDiscovery,
        startingAt base: UInt32 = 0
    ) throws(InstrumentError) -> InstrumentedFile {
        guard !discovery.candidates.isEmpty else {
            return InstrumentedFile(
                source: source, runtime: "", mutants: [], runtimeToken: "", nextIndex: base)
        }

        let bytes = Array(source.utf8)
        let token = Runtime.token(for: discovery.path, digest: discovery.sourceDigest)

        // Grouped by the expression a guard would wrap: several rules at one expression are
        // alternatives at one site, not sites of their own.
        var sites: [SourceSpan: [Candidate]] = [:]
        for candidate in discovery.candidates {
            sites[candidate.guardSpan, default: []].append(candidate)
        }

        let arranged = sites.keys.sorted().map { (span: $0, value: sites[$0] ?? []) }
        guard let forest = IntervalForest(arranged) else {
            // Named, both of them. "Somewhere in this file" leaves a reader grepping a
            // catalogue for a filename - which is what somebody did, and it worked only
            // because they already suspected their own rows. Two spans is two lines to go
            // and look at.
            let conflict = IntervalForest<[Candidate]>.conflict(in: arranged)
            throw InstrumentError(
                """
                \(discovery.path) holds two mutation sites that overlap without either \
                containing the other, and no splice order satisfies both - whichever were \
                written first would destroy the bytes the other was measured against. \
                \(Self.naming(conflict, in: discovery))
                """
            )
        }

        let numbered = Self.number(forest, token: token, discovery: discovery, from: base)

        let spliced = Self.splice(
            forest,
            bytes: bytes,
            token: token,
            numbered: numbered,
            comments: discovery.lineComments)
        let runtime = Runtime.source(
            token: token, count: numbered.mutants.count, base: base)
        return InstrumentedFile(
            source: spliced.text + runtime,
            runtime: runtime,
            mutants: try Self.place(
                numbered.mutants,
                at: spliced.placements,
                within: spliced.sites,
                in: discovery
            ),
            runtimeToken: token,
            nextIndex: base + UInt32(numbered.mutants.count)
        )
    }

    /// Walks the file once, putting each rendered site in place of the bytes it replaces.
    private static func splice(
        _ forest: IntervalForest<[Candidate]>,
        bytes: [UInt8],
        token: String,
        numbered: Numbering,
        comments: [SourceSpan]
    ) -> Rendered {
        var rewritten = ""
        var produced = 0
        var placements: [UInt32: SourceSpan] = [:]
        var guards: [UInt32: SourceSpan] = [:]
        var cursor = 0
        for root in forest.roots {
            let span = root.span
            let lead = String(decoding: bytes[cursor..<span.start], as: UTF8.self)
            rewritten += lead
            produced += lead.utf8.count

            let rendered = Self.render(
                root,
                bytes: bytes,
                token: token,
                indices: numbered.indices,
                comments: comments)
            rewritten += rendered.text
            for (index, relative) in rendered.placements {
                placements[index] = relative.shifted(by: produced)
            }
            for (index, relative) in rendered.sites {
                guards[index] = relative.shifted(by: produced)
            }
            produced += rendered.text.utf8.count
            cursor = span.end
        }
        rewritten += String(decoding: bytes[cursor...], as: UTF8.self)
        return Rendered(text: rewritten, placements: placements, sites: guards)
    }

    /// Tells every numbered mutant where it landed.
    ///
    /// A mutant that was numbered but never rendered is an instrumenter defect, and the
    /// one thing it must not do is travel onward: attribution would then have a mutant
    /// with no place in the file, and the compiler diagnostic that belongs to it would be
    /// reported as an error in the original program instead. Muter's four hundred false
    /// regressions began as exactly this - a mutant in the catalogue that was not in the
    /// file - so it is raised here rather than carried.
    private static func place(
        _ mutants: [Numbered],
        at placements: [UInt32: SourceSpan],
        within sites: [UInt32: SourceSpan],
        in discovery: FileDiscovery
    ) throws(InstrumentError) -> [InstrumentedMutant] {
        var placed: [InstrumentedMutant] = []
        placed.reserveCapacity(mutants.count)
        for mutant in mutants {
            guard let span = placements[mutant.index], let site = sites[mutant.index] else {
                throw InstrumentError(
                    """
                    \(discovery.path): mutant \(mutant.index) (\(mutant.rule.rendered)) was \
                    numbered but never rendered into the file. This is a defect in the \
                    instrumenter, not in the file.
                    """
                )
            }
            placed.append(
                InstrumentedMutant(
                    identity: mutant.identity,
                    path: discovery.path,
                    index: mutant.index,
                    marker: mutant.marker,
                    span: mutant.span,
                    instrumentedSpan: span,
                    siteSpan: site,
                    rule: mutant.rule,
                    original: mutant.original,
                    replacement: mutant.replacement
                )
            )
        }
        return placed
    }

    /// What was numbered, and the index each edit's guard spells.
    private struct Numbering {
        var mutants: [Numbered] = []

        /// The indices one site's candidates were given, in the order the site lists them.
        ///
        /// Keyed by site rather than by edit, and a list rather than a single index,
        /// because two candidates at one site can edit the same bytes: `a && b` becoming
        /// `a` and becoming `b` both replace the whole expression. Keying by the edit
        /// collapsed them onto one number, and the second was numbered but never rendered.
        var indices: [SourceSpan: [UInt32]] = [:]
    }

    /// A mutant that has an index but does not yet know where it landed.
    ///
    /// It exists so that ``InstrumentedMutant`` cannot: a mutant in an instrumented file
    /// always knows its place in that file, which is what attribution rests on. Numbering
    /// runs before rendering, so this is the shape of the thing in between.
    private struct Numbered {
        let identity: MutantIdentity
        let index: UInt32
        let marker: String
        let span: SourceSpan
        let rule: RuleIdentifier
        let original: String
        let replacement: String
    }

    /// Gives every mutant a number, innermost site first.
    ///
    /// Contiguous because a guard is an equality test against one integer, and continued
    /// across files because the environment variable the runtime reads is one value for
    /// the whole process.
    private static func number(
        _ forest: IntervalForest<[Candidate]>,
        token: String,
        discovery: FileDiscovery,
        from base: UInt32
    ) -> Numbering {
        var numbering = Numbering()
        var next = base
        for node in forest.innermostFirst {
            var assigned: [UInt32] = []
            for candidate in node.values.flatMap({ $0 }) {
                assigned.append(next)
                numbering.mutants.append(
                    Numbered(
                        identity: Self.identity(of: candidate, in: discovery),
                        index: next,
                        marker: Runtime.marker(token: token, index: next),
                        span: candidate.span,
                        rule: candidate.rule,
                        original: candidate.original,
                        replacement: candidate.replacement
                    )
                )
                next += 1
            }
            numbering.indices[node.span] = assigned
        }
        return numbering
    }

    /// Renders one site: its mutants as alternatives, its children inside the original side.
    ///
    /// The recursion runs innermost-first through the forest, so a child is rendered before
    /// the bytes around it move.
    private static func render(
        _ node: IntervalForest<[Candidate]>.Node,
        bytes: [UInt8],
        token: String,
        indices: [SourceSpan: [UInt32]],
        comments: [SourceSpan]
    ) -> Rendered {
        // The original side keeps its bytes, with any nested guards spliced into it.
        var original = ""
        var produced = 0
        var placements: [UInt32: SourceSpan] = [:]
        var sites: [UInt32: SourceSpan] = [:]
        var cursor = node.span.start
        for child in node.children {
            let lead = String(decoding: bytes[cursor..<child.span.start], as: UTF8.self)
            original += lead
            produced += lead.utf8.count

            let rendered = render(
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

        // The mutated sides carry the pristine expression with one edit applied, because
        // only one mutant is ever awake and a nested guard in here would never fire.
        var rendered = "(\(original))"
        // The children just placed sit one byte in, past the opening parenthesis.
        placements = placements.compactMapValues { $0.shifted(by: 1) }
        sites = sites.compactMapValues { $0.shifted(by: 1) }

        // Zipped rather than looked up: numbering walked this same list in this same
        // order, so position is the join. A length mismatch drops a mutant here, and the
        // placement check then refuses the file rather than shipping a phantom.
        let alternatives = Array(zip(node.values.flatMap { $0 }, indices[node.span] ?? []))
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
        return Rendered(text: rendered, placements: placements, sites: sites)
    }

    /// One site's text, and where inside it each mutant's copy of the expression landed.
    private struct Rendered {
        var text: String
        /// Byte spans of each mutant's own copy, relative to the start of ``text``.
        var placements: [UInt32: SourceSpan]
        /// Byte spans of the whole guard each mutant belongs to, relative the same way.
        var sites: [UInt32: SourceSpan]
    }

    /// The site's bytes with one candidate's edit applied, flattened onto one line.
    ///
    /// Flattened because the original side of the guard keeps every newline the file had,
    /// so a mutated copy that kept its own would add them - and every line number in an
    /// instrumented file has to equal the original's, or the coverage a run reads back
    /// afterwards is about different lines than the ones it measured.
    ///
    /// Line comments come out on the way. A comment runs to the end of its line, so joining
    /// the lines would put the rest of the guard - the closing parenthesis included - inside
    /// it. Taking it out costs nothing: a comment has no meaning to a compiler, and the
    /// original copy beside it keeps every byte the file had, so a person reading the tree
    /// or running `apply` still sees their own comment.
    ///
    /// This was a refusal, and the refusal stopped the run: one site, one file, after the
    /// whole instrument-and-validate pass had already been paid for. Measured on a package
    /// with 87 commented expressions across 32 files - four runs, four stops, one site each.
    /// It could not be done here because it cannot be done on bytes: `//` inside a string
    /// literal is not a comment, and the refusal matched two characters. Discovery has the
    /// tree and says which bytes are comments; this takes exactly those.
    private static func apply(
        _ candidate: Candidate,
        to bytes: [UInt8],
        within site: SourceSpan,
        hiding comments: [SourceSpan]
    ) -> String {
        let prefix = Self.bytes(bytes, from: site.start, to: candidate.span.start, less: comments)
        let suffix = Self.bytes(bytes, from: candidate.span.end, to: site.end, less: comments)
        return (prefix + candidate.replacement + suffix).replacingNewlines(with: " ")
    }

    private static func identity(
        of candidate: Candidate, in discovery: FileDiscovery
    )
        -> MutantIdentity
    {
        MutantIdentity(
            MutantIdentity.Inputs(
                path: discovery.path,
                enclosingDeclaration: candidate.enclosingDeclaration,
                rule: candidate.rule,
                span: candidate.span,
                sourceDigest: discovery.sourceDigest,
                originalBytes: Digest.of(candidate.original),
                replacementBytes: Digest.of(candidate.replacement)
            )
        )
    }
}

extension String {
    /// Every newline replaced, without reaching for Foundation.
    func replacingNewlines(with replacement: String) -> String {
        split(separator: "\n", omittingEmptySubsequences: false).joined(separator: replacement)
    }
}
