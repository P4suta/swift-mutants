// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// What a mutant is called, and why it keeps that name.
///
/// An identity decides which cached outcome applies to a mutant, whether an expectation
/// somebody wrote down is still about this mutant, and which shard it lands in. So it has
/// to depend on everything that makes the mutant what it is, and on nothing else —
/// particularly not on where the tree happened to be sitting when it was computed.
@Suite("Mutant identity")
struct MutantIdentityTests {

    static func inputs(
        path pathText: String = "Sources/Codec/Header.swift",
        declaration: String = "s:4Demo6HeaderV5parseyACSSKFZ",
        rule ruleText: String = "add-to-sub@1",
        start: Int = 512,
        end: Int = 517,
        source: String = "the whole file as it was read",
        original: String = "a + b",
        replacement: String = "a - b"
    ) -> MutantIdentity.Inputs {
        // A malformed fixture is a mistake in this file, not a property of the code
        // under test, so it traps here rather than failing an assertion elsewhere.
        guard let path = WorkspaceRelativePath(pathText),
            let rule = RuleIdentifier(ruleText),
            let span = SourceSpan(start: start, end: end)
        else {
            fatalError("malformed identity fixture")
        }
        return MutantIdentity.Inputs(
            path: path,
            enclosingDeclaration: declaration,
            rule: rule,
            span: span,
            sourceDigest: Digest.of(source),
            originalBytes: Digest.of(original),
            replacementBytes: Digest.of(replacement)
        )
    }

    @Test("is the same for the same mutant")
    func isDeterministic() {
        let first = MutantIdentity(Self.inputs())
        let second = MutantIdentity(Self.inputs())
        #expect(first == second)
    }

    /// The one property the whole design turns on: the tree is read in one place and
    /// mutated in a disposable copy somewhere else, so a mutant has several absolute paths
    /// during a single run. The type system already refuses to hold one — this asserts the
    /// consequence.
    @Test("does not depend on where the tree is")
    func doesNotDependOnLocation() {
        #expect(
            MutantIdentity(Self.inputs(path: "./Sources/Codec/Header.swift"))
                == MutantIdentity(Self.inputs(path: "Sources//Codec/Header.swift"))
        )
    }

    /// Every input has to reach the digest. A field left out of the builder is the kind of
    /// omission that produces two mutants sharing an identity, one silently adopting the
    /// other's verdict.
    @Test(
        "changes when any single input changes",
        arguments: [
            "path", "declaration", "rule name", "rule version", "span start", "span end",
            "source digest", "original bytes", "replacement bytes",
        ]
    )
    func everyInputParticipates(field: String) {
        let baseline = MutantIdentity(Self.inputs())
        let altered: MutantIdentity.Inputs =
            switch field {
            case "path": Self.inputs(path: "Sources/Codec/Other.swift")
            case "declaration": Self.inputs(declaration: "s:4Demo6HeaderV6formatyACSSKFZ")
            case "rule name": Self.inputs(rule: "sub-to-add@1")
            case "rule version": Self.inputs(rule: "add-to-sub@2")
            case "span start": Self.inputs(start: 513)
            case "span end": Self.inputs(end: 518)
            case "source digest": Self.inputs(source: "the file after an unrelated edit")
            case "original bytes": Self.inputs(original: "a * b")
            default: Self.inputs(replacement: "a / b")
            }
        #expect(MutantIdentity(altered) != baseline, "\(field) did not reach the digest")
    }

    /// The field sequence is the identity scheme. It is recomputed here from the documented
    /// order rather than compared against a constant, so that a change to the order fails
    /// with a diff a reader can act on.
    @Test("hashes the documented field sequence")
    func matchesTheDocumentedFieldSequence() {
        let inputs = Self.inputs()
        let expected =
            DigestBuilder()
            .adding(SwiftMutantsCore.identitySchemeVersion)
            .adding(inputs.path.rendered)
            .adding(inputs.enclosingDeclaration)
            .adding(inputs.rule.rendered)
            .adding(inputs.span.start)
            .adding(inputs.span.end)
            .adding(inputs.sourceDigest)
            .adding(inputs.originalBytes)
            .adding(inputs.replacementBytes)
            .finalize()
        #expect(MutantIdentity(inputs).digest == expected)
    }

    /// A regression vector. It has no meaning beyond "this build computes what the build
    /// that recorded it computed" - which is exactly the thing that must not change by
    /// accident, because every cached outcome and every recorded expectation in every
    /// project depends on it.
    @Test("matches its recorded vector")
    func matchesRecordedVector() {
        #expect(
            MutantIdentity(Self.inputs()).rendered
                == "bb86a00138e3c63b7fe570c408202aa231cec5e07d8b66d62184ab6396bf741b"
        )
    }

    @Test("shows a short form that is a prefix of the full identity")
    func shortForm() {
        let identity = MutantIdentity(Self.inputs())
        #expect(identity.rendered.hasPrefix(identity.shortForm))
        #expect(identity.shortForm.count == 20)
    }

    @Test("encodes as the full hexadecimal identity, never the short form")
    func codableRoundTrip() throws {
        let identity = MutantIdentity(Self.inputs())
        let json = try JSONTestSupport.canonicalJSON(of: ["id": identity])
        #expect(json == #"{"id":"\#(identity.rendered)"}"#)
        #expect(
            try JSONTestSupport.decode([String: MutantIdentity].self, from: json)["id"] == identity)
    }
}
