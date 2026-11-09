// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// Mutation identities include source bytes, location, declaration, and rule.
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
    ) throws -> MutantIdentity.Inputs {
        let path = try #require(WorkspaceRelativePath(pathText))
        let rule = try #require(RuleIdentifier(ruleText))
        let span = try #require(SourceSpan(start: start, end: end))
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
    func isDeterministic() throws {
        let first = MutantIdentity(try Self.inputs())
        let second = MutantIdentity(try Self.inputs())
        #expect(first == second)
    }

    /// The one property the whole design turns on: the tree is read in one place and mutated in a disposable copy somewhere else, so a mutant has several absolute paths during a single run.
    /// The type system already refuses to hold one — this asserts the consequence.
    @Test("does not depend on where the tree is")
    func doesNotDependOnLocation() throws {
        #expect(
            MutantIdentity(try Self.inputs(path: "./Sources/Codec/Header.swift"))
                == MutantIdentity(try Self.inputs(path: "Sources//Codec/Header.swift"))
        )
    }

    /// Every input has to reach the digest.
    /// A field left out of the builder is the kind of omission that produces two mutants sharing an identity, one silently adopting the other's verdict.
    @Test(
        "changes when any single input changes",
        arguments: [
            "path", "declaration", "rule name", "rule version", "span start", "span end",
            "source digest", "original bytes", "replacement bytes",
        ]
    )
    func everyInputParticipates(field: String) throws {
        let baseline = MutantIdentity(try Self.inputs())
        let altered: MutantIdentity.Inputs =
            switch field {
            case "path": try Self.inputs(path: "Sources/Codec/Other.swift")
            case "declaration": try Self.inputs(declaration: "s:4Demo6HeaderV6formatyACSSKFZ")
            case "rule name": try Self.inputs(rule: "sub-to-add@1")
            case "rule version": try Self.inputs(rule: "add-to-sub@2")
            case "span start": try Self.inputs(start: 513)
            case "span end": try Self.inputs(end: 518)
            case "source digest": try Self.inputs(source: "the file after an unrelated edit")
            case "original bytes": try Self.inputs(original: "a * b")
            default: try Self.inputs(replacement: "a / b")
            }
        #expect(MutantIdentity(altered) != baseline, "\(field) did not reach the digest")
    }

    /// The field sequence is the identity scheme.
    /// It is recomputed here from the documented order rather than compared against a constant, so that a change to the order fails with a diff a reader can act on.
    @Test("hashes the documented field sequence")
    func matchesTheDocumentedFieldSequence() throws {
        let inputs = try Self.inputs()
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

    /// The stored digest detects accidental changes to the identity scheme.
    @Test("matches its recorded vector")
    func matchesRecordedVector() throws {
        #expect(
            MutantIdentity(try Self.inputs()).rendered
                == "bb86a00138e3c63b7fe570c408202aa231cec5e07d8b66d62184ab6396bf741b"
        )
    }

    @Test("shows a short form that is a prefix of the full identity")
    func shortForm() throws {
        let identity = MutantIdentity(try Self.inputs())
        #expect(identity.rendered.hasPrefix(identity.shortForm))
        #expect(identity.shortForm.count == 20)
    }

    @Test("encodes as the full hexadecimal identity, never the short form")
    func codableRoundTrip() throws {
        let identity = MutantIdentity(try Self.inputs())
        let json = try JSONTestSupport.canonicalJSON(of: ["id": identity])
        #expect(json == #"{"id":"\#(identity.rendered)"}"#)
        #expect(
            try JSONTestSupport.decode([String: MutantIdentity].self, from: json)["id"] == identity)
    }
}
