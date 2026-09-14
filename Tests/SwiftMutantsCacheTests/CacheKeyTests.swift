// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsCache

/// What a mutant's answer depends on, and therefore what may be remembered.
///
/// A cache is only worth having if it is right, and the way an outcome cache is wrong is
/// silent: it answers `survived` for a mutant a test now catches, and the score goes up
/// while the tests got no better. So the key has to name everything that could change the
/// answer, and nothing that could not - the first makes it unsound, the second makes it
/// useless.
///
/// What could change the answer is the mutant itself, and the behaviour of every file the
/// tests that reach it execute. Nothing else can: a file no covering test ever runs cannot
/// change what those tests conclude. The probe already knows which files each test reached,
/// because it records which guards each test evaluated and every guard is in a file - so
/// the dependency set is not estimated, it is observed.
@Suite("Cache keys")
struct CacheKeyTests {

    static func identity(
        rule: String = "lt-to-le@1", span: (Int, Int) = (10, 11)
    )
        -> MutantIdentity
    {
        guard let path = WorkspaceRelativePath("Sources/Codec/Header.swift"),
            let rule = RuleIdentifier(rule),
            let span = SourceSpan(start: span.0, end: span.1)
        else {
            fatalError("malformed fixture")
        }
        return MutantIdentity(
            MutantIdentity.Inputs(
                path: path,
                enclosingDeclaration: "s:7Example1fyySiF",
                rule: rule,
                span: span,
                sourceDigest: Digest.of("a < b"),
                originalBytes: Digest.of("<"),
                replacementBytes: Digest.of("<=")
            ))
    }

    static func key(
        _ identity: MutantIdentity? = nil,
        dependencies: [String] = ["one", "two"],
        version: String = "1.2.3"
    ) -> CacheKey {
        CacheKey(
            mutant: identity ?? Self.identity(),
            dependencies: dependencies.map { Digest.of($0) },
            toolVersion: version
        )
    }

    /// Every expectation below is about the digest rather than about the value, because
    /// the digest is the whole of what a cache stores and looks up. Two keys that differ
    /// as values and agree as digests would be one entry answering two questions, which is
    /// the unsound direction.
    @Test("is the same for the same question")
    func isDeterministic() {
        let asked = Self.key()
        let askedAgain = Self.key(dependencies: ["two", "one"])
        #expect(asked.digest == askedAgain.digest)
    }

    /// The order files were observed in is an accident of which worker finished first. A
    /// key that depended on it would miss every time.
    @Test("does not depend on the order its dependencies arrived in")
    func orderDoesNotMatter() {
        #expect(
            Self.key(dependencies: ["one", "two"]).digest
                == Self.key(dependencies: ["two", "one"]).digest
        )
    }

    /// Duplicates are an accident too: two tests reaching the same file report it twice.
    @Test("does not depend on how many times a file was named")
    func duplicatesDoNotMatter() {
        #expect(
            Self.key(dependencies: ["one", "two"]).digest
                == Self.key(dependencies: ["one", "two", "one"]).digest
        )
    }

    @Test("changes when the mutant does")
    func changesWithTheMutant() {
        #expect(Self.key().digest != Self.key(Self.identity(rule: "lt-to-le@2")).digest)
        #expect(Self.key().digest != Self.key(Self.identity(span: (10, 12))).digest)
    }

    /// The whole point. A file the covering tests execute changed, so the answer has to be
    /// asked again.
    @Test("changes when a file the tests execute does")
    func changesWithADependency() {
        #expect(Self.key().digest != Self.key(dependencies: ["one", "three"]).digest)
    }

    /// A file nobody runs cannot change what a test concludes, and treating it as a
    /// dependency would throw away every hit for no safety at all.
    @Test("is unchanged by a file that is not a dependency")
    func unrelatedFilesDoNotMatter() {
        #expect(
            Self.key(dependencies: ["one"]).digest
                != Self.key(dependencies: ["one", "two"]).digest)
    }

    /// A different build of this tool may answer differently - a rule may mean something
    /// new, a verdict may be decided differently - and an answer from one is not evidence
    /// about the other.
    @Test("changes when the tool does")
    func changesWithTheTool() {
        #expect(Self.key().digest != Self.key(version: "1.2.4").digest)
    }

    /// A mutant with no dependencies at all is a mutant nothing reaches, and that is a
    /// real answer worth keeping rather than a missing one.
    @Test("holds a mutant nothing reaches")
    func nothingReachesIt() {
        #expect(Self.key(dependencies: []).digest != Self.key(dependencies: ["one"]).digest)
    }

    /// The digest is what gets written down, so it has to be a name rather than a number
    /// that happens to differ on this machine.
    @Test("names itself in full")
    func namesItselfInFull() {
        #expect(Self.key().digest.hexadecimal.count == 64)
    }
}
