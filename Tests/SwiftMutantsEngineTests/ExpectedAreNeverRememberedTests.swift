// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCache
import SwiftMutantsCore
import SwiftMutantsExecute
import Testing

@testable import SwiftMutantsEngine

/// An expected survivor is measured on every run, cache or no cache.
///
/// The reason is what an expectation is for. It is not a note that a mutant may be ignored,
/// it is a claim about the mutant that the next run has to test - and a claim answered from
/// last week's cache is a claim nobody tested. Somebody writes the missing assertion, the
/// mutant starts dying, and a cached `survived` reports the expectation as still met while
/// the note in their configuration has become untrue.
///
/// Both directions matter and both fall out of the same edit: the mutant has no cache key,
/// so nothing can be looked up for it and nothing is written down about it either.
@Suite("Expected mutants are never remembered")
struct ExpectedAreNeverRememberedTests {

    static var path: WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture")
        }
        return path
    }

    static var rule: RuleIdentifier {
        guard let rule = RuleIdentifier("lt-to-le@1") else { fatalError("malformed fixture") }
        return rule
    }

    static var span: SourceSpan {
        guard let span = SourceSpan(start: 0, end: 1) else { fatalError("malformed fixture") }
        return span
    }

    static func identity(_ name: String) -> MutantIdentity {
        MutantIdentity(
            MutantIdentity.Inputs(
                path: Self.path,
                enclosingDeclaration: name,
                rule: Self.rule,
                span: Self.span,
                sourceDigest: Digest.of("subject"),
                originalBytes: Digest.of("<"),
                replacementBytes: Digest.of("<=")
            ))
    }

    /// One mutant, reached by one test, with everything its answer rests on digested.
    static func remembering(
        expecting expected: Set<String>, holding answers: [(MutantIdentity, Outcome)] = []
    ) -> Remembering {
        let identities: [UInt32: MutantIdentity] = [1: Self.identity("a"), 2: Self.identity("b")]
        var cache = OutcomeCache()
        let digests: [WorkspaceRelativePath: Digest] = [Self.path: Digest.of("subject")]
        let files: [UInt32: WorkspaceRelativePath] = [1: Self.path, 2: Self.path]
        let coverage = Coverage(byMutant: [1: ["T/t"], 2: ["T/t"]], reach: ["T/t": [1, 2]])

        // The keys have to be the ones a run would use, so they are taken from a
        // remembering that expects nothing rather than spelled out a second time here.
        let everything = Remembering.of(
            MutantCatalogue(files: files, identities: identities),
            coverage: coverage,
            digests: digests,
            cache: OutcomeCache(),
            expecting: []
        )
        for (identity, outcome) in answers {
            guard let index = identities.first(where: { $0.value == identity })?.key,
                let key = everything.key(for: index)
            else { fatalError("the fixture's own mutant has no key") }
            cache = cache.recording(
                key,
                CachedAnswer(
                    outcome: outcome, killedBy: [], testsStarted: 1, durationMilliseconds: 1))
        }
        return Remembering.of(
            MutantCatalogue(files: files, identities: identities),
            coverage: coverage,
            digests: digests,
            cache: cache,
            expecting: expected
        )
    }

    @Test("answers an ordinary mutant from the cache")
    func ordinaryIsAnswered() {
        let remembering = Self.remembering(
            expecting: [],
            holding: [(Self.identity("a"), .survived)]
        )
        #expect(remembering.answer(for: 1)?.outcome == .survived)
    }

    @Test("asks an expected mutant again even though the cache holds it")
    func expectedIsAsked() {
        let remembering = Self.remembering(
            expecting: [Self.identity("a").rendered],
            holding: [(Self.identity("a"), .survived)]
        )
        #expect(remembering.answer(for: 1) == nil)
    }

    /// Expecting one mutant does not stop the rest of the package being remembered. An
    /// expectation costs one process, not a run.
    @Test("still answers the mutants around it")
    func neighboursAreAnswered() {
        let remembering = Self.remembering(
            expecting: [Self.identity("a").rendered],
            holding: [(Self.identity("a"), .survived), (Self.identity("b"), .killed)]
        )
        #expect(remembering.answer(for: 1) == nil)
        #expect(remembering.answer(for: 2)?.outcome == .killed)
    }

    /// The other direction: this run must not write down an answer the next one would
    /// take, or the expectation is untested every run after the first.
    @Test("writes nothing down about an expected mutant")
    func expectedIsNotWrittenDown() {
        let remembering = Self.remembering(expecting: [Self.identity("a").rendered])
        let kept = remembering.recording(
            [
                Self.result(Self.identity("a"), .survived),
                Self.result(Self.identity("b"), .survived),
            ],
            by: [Self.identity("a"): 1, Self.identity("b"): 2]
        )
        let asking = Self.remembering(expecting: [])
        #expect(kept.answer(for: asking.key(for: 1) ?? Digest.of("")) == nil)
        #expect(kept.answer(for: asking.key(for: 2) ?? Digest.of("")) != nil)
    }

    static func result(_ identity: MutantIdentity, _ outcome: Outcome) -> MutantResult {
        MutantResult(
            identity: identity,
            path: Self.path,
            rule: Self.rule,
            span: Self.span,
            original: "<",
            replacement: "<=",
            verdict: Verdict(
                outcome: outcome,
                killedBy: [],
                firstFailure: nil,
                startedTests: ["T/t"],
                durationMilliseconds: 1,
                termination: .exited(0)
            ),
            attempts: 1
        )
    }
}
