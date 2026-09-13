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
    public static func file(
        _ source: String,
        discovery: FileDiscovery
    ) throws(InstrumentError) -> InstrumentedFile {
        guard !discovery.candidates.isEmpty else {
            return InstrumentedFile(source: source, runtime: "", mutants: [], runtimeToken: "")
        }

        let bytes = Array(source.utf8)
        let token = Runtime.token(for: discovery.path, digest: discovery.sourceDigest)

        // Grouped by the expression a guard would wrap: several rules at one expression are
        // alternatives at one site, not sites of their own.
        var sites: [SourceSpan: [Candidate]] = [:]
        for candidate in discovery.candidates {
            sites[candidate.guardSpan, default: []].append(candidate)
        }

        guard
            let forest = IntervalForest(
                sites.keys.sorted().map { (span: $0, value: sites[$0] ?? []) }
            )
        else {
            throw InstrumentError(
                """
                \(discovery.path) holds mutation sites that overlap without nesting, which no \
                splice order can satisfy. This is a defect in discovery rather than in the file.
                """
            )
        }

        let numbered = Self.number(forest, token: token, discovery: discovery)

        var rewritten = ""
        var cursor = 0
        for root in forest.roots {
            let span = root.span
            rewritten += String(decoding: bytes[cursor..<span.start], as: UTF8.self)
            rewritten += try Self.render(
                root, bytes: bytes, token: token, indices: numbered.indices)
            cursor = span.end
        }
        rewritten += String(decoding: bytes[cursor...], as: UTF8.self)

        let runtime = Runtime.source(token: token, count: numbered.mutants.count)
        return InstrumentedFile(
            source: rewritten + runtime,
            runtime: runtime,
            mutants: numbered.mutants,
            runtimeToken: token
        )
    }

    /// What was numbered, and the index each edit's guard spells.
    private struct Numbering {
        var mutants: [InstrumentedMutant] = []
        var indices: [SourceSpan: UInt32] = [:]
    }

    /// Gives every mutant a dense index, innermost site first.
    ///
    /// Dense because a guard is an equality test against one integer, and per file because
    /// the runtime that holds that integer is per file.
    private static func number(
        _ forest: IntervalForest<[Candidate]>,
        token: String,
        discovery: FileDiscovery
    ) -> Numbering {
        var numbering = Numbering()
        var next: UInt32 = 0
        for node in forest.innermostFirst {
            for candidate in node.values.flatMap({ $0 }) {
                numbering.indices[candidate.span] = next
                numbering.mutants.append(
                    InstrumentedMutant(
                        identity: Self.identity(of: candidate, in: discovery),
                        index: next,
                        marker: Runtime.marker(token: token, index: next),
                        span: candidate.span,
                        rule: candidate.rule
                    )
                )
                next += 1
            }
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
        indices: [SourceSpan: UInt32]
    ) throws(InstrumentError) -> String {
        // The original side keeps its bytes, with any nested guards spliced into it.
        var original = ""
        var cursor = node.span.start
        for child in node.children {
            original += String(decoding: bytes[cursor..<child.span.start], as: UTF8.self)
            original += try render(child, bytes: bytes, token: token, indices: indices)
            cursor = child.span.end
        }
        original += String(decoding: bytes[cursor..<node.span.end], as: UTF8.self)

        // The mutated sides carry the pristine expression with one edit applied, because
        // only one mutant is ever awake and a nested guard in here would never fire.
        var rendered = "(\(original))"
        for candidate in node.values.flatMap({ $0 }).reversed() {
            guard let index = indices[candidate.span] else { continue }
            let mutated = try Self.apply(candidate, to: bytes, within: node.span)
            rendered =
                "(\(Runtime.guardCall(token: token, index: index)) ? (\(mutated)) : \(rendered))"
        }
        return rendered
    }

    /// The site's bytes with one candidate's edit applied, flattened onto one line.
    ///
    /// Flattened because the original side of the guard keeps every newline the file had,
    /// so a mutated copy that kept its own would add them.
    private static func apply(
        _ candidate: Candidate,
        to bytes: [UInt8],
        within site: SourceSpan
    ) throws(InstrumentError) -> String {
        let prefix = String(decoding: bytes[site.start..<candidate.span.start], as: UTF8.self)
        let suffix = String(decoding: bytes[candidate.span.end..<site.end], as: UTF8.self)
        let text = prefix + candidate.replacement + suffix
        guard !text.contains("//") else {
            throw InstrumentError(
                """
                the expression at \(site.start)..<\(site.end) holds a line comment, which \
                cannot survive being flattened onto one line
                """
            )
        }
        return text.replacingNewlines(with: " ")
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
