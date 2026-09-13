// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// Builds the digest of a sequence of fields, unambiguously.
///
/// Every identity in swift-mutants is a hash over several fields — a path, a rule, a byte
/// span, the bytes before and after. Hashing them by plain concatenation is the classic
/// way to get an identity that is not one: `("ab", "c")` and `("a", "bc")` produce the same
/// bytes, so two different mutants would share an ID, one would adopt the other's cached
/// outcome, and nothing anywhere would say so.
///
/// Length-prefixing each field removes the ambiguity, and these tests are what hold that
/// property in place.
@Suite("Digest builder")
struct DigestBuilderTests {

    @Test("distinguishes field boundaries that plain concatenation would lose")
    func fieldBoundariesAreUnambiguous() {
        let left = DigestBuilder().adding("ab").adding("c").finalize()
        let right = DigestBuilder().adding("a").adding("bc").finalize()
        #expect(left != right)
    }

    @Test("distinguishes an empty field from an absent one")
    func emptyIsNotAbsent() {
        let withEmpty = DigestBuilder().adding("a").adding("").adding("b").finalize()
        let without = DigestBuilder().adding("a").adding("b").finalize()
        #expect(withEmpty != without)
    }

    @Test("distinguishes field order")
    func orderMatters() {
        #expect(
            DigestBuilder().adding("a").adding("b").finalize()
                != DigestBuilder().adding("b").adding("a").finalize()
        )
    }

    @Test("gives the same answer for the same fields")
    func isDeterministic() {
        func build() -> Digest {
            DigestBuilder()
                .adding("Sources/Foo.swift")
                .adding(42)
                .adding(Digest.of("payload"))
                .finalize()
        }
        let first = build()
        let second = build()
        #expect(first == second)
    }

    /// An integer field is fixed-width, so a span of `1..<23` cannot collide with a span
    /// of `12..<3` through the decimal digits running together.
    @Test("distinguishes integer fields that share their digits")
    func integerFieldsAreFixedWidth() {
        #expect(
            DigestBuilder().adding(1).adding(23).finalize()
                != DigestBuilder().adding(12).adding(3).finalize()
        )
    }

    @Test("distinguishes a string field from an integer field with the same text")
    func fieldTypesAreDistinguished() {
        #expect(DigestBuilder().adding("42").finalize() != DigestBuilder().adding(42).finalize())
    }

    /// The encoding is part of the identity scheme, so it is pinned rather than left to
    /// whatever the implementation happens to do. A change here changes every mutant ID
    /// in every project, and must therefore be a deliberate bump of
    /// `SwiftMutantsCore.identitySchemeVersion`.
    @Test("encodes each field as an eight-byte big-endian length, then a tag, then bytes")
    func encodingIsPinned() {
        // "hi" -> length 2 (0x00…02), tag 's', bytes 'h','i'
        let expected: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 2, UInt8(ascii: "s"), 0x68, 0x69]
        #expect(DigestBuilder().adding("hi").finalize() == Digest.of(expected))
    }

    @Test("is a value: adding to a copy does not disturb the original")
    func isAValue() {
        let base = DigestBuilder().adding("a")
        let one = base.adding("b").finalize()
        let two = base.adding("b").finalize()
        #expect(one == two)
        #expect(base.adding("c").finalize() != one)
    }
}
