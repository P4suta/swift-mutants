// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
public import SwiftMutantsDiscover

/// Instruments source mutations behind runtime activation indices.
/// Preserves original source line breaks and keeps mutated alternatives on one line.
/// Nested mutated alternatives contain pristine inner expressions.
public enum Instrument {

    /// Instruments a file using discovery computed from the same source.
    /// Continue `startingAt` from the previous file's ``InstrumentedFile/nextIndex``.
    /// Throws `InstrumentError` for overlapping sites or missing rendered placements.
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

        var sites: [SourceSpan: [Candidate]] = [:]
        for candidate in discovery.candidates {
            sites[candidate.guardSpan, default: []].append(candidate)
        }

        let arranged = sites.keys.sorted().map { (span: $0, value: sites[$0] ?? []) }
        guard let forest = IntervalForest(arranged) else {
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

    /// Binds every numbered mutation to its rendered span and guard site.
    /// Rejects missing placements before returning an instrumented file.
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

        /// Multiple replacements at one site receive distinct activation indices.
        var indices: [SourceSpan: [UInt32]] = [:]
    }

    /// A mutation with an activation index but no rendered location.
    private struct Numbered {
        let identity: MutantIdentity
        let index: UInt32
        let marker: String
        let span: SourceSpan
        let rule: RuleIdentifier
        let original: String
        let replacement: String
    }

    /// Assigns consecutive indices, innermost site first.
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

    /// Applies one candidate within its guard site and flattens Swift line breaks.
    static func apply(
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
    /// Replaces Swift line breaks while preserving other Unicode separators.
    func replacingNewlines(with replacement: String) -> String {
        split(omittingEmptySubsequences: false) { SourceLineBreak(rawValue: $0) != nil }
            .joined(separator: replacement)
    }
}
