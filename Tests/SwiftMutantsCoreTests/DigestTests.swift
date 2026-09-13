// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// SHA-256, implemented here rather than imported.
///
/// A mutant identity is a digest, and an identity that changed because a dependency was
/// upgraded would silently invalidate every cached outcome and every recorded expectation
/// in every project using the tool. The sibling projects write their own glob engine for
/// exactly this reason - "mutant IDs must not depend on which one is installed" - and the
/// same argument applies with more force to the hash itself.
///
/// Owning it also keeps `SwiftMutantsCore` free of dependencies, which is what lets the
/// unit tier build in the time an inner loop can afford.
///
/// The correctness question is closed rather than open: the vectors below are from
/// FIPS 180-4 and its published test data.
@Suite("SHA-256")
struct DigestTests {

    @Test(
        "matches the FIPS 180-4 vectors",
        arguments: [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
            (
                "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
                    + "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
                "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
            ),
        ]
    )
    func fipsVectors(input: String, expected: String) {
        #expect(Digest.of(input).hexadecimal == expected)
    }

    /// The vector that exercises padding across many blocks. It is the one a
    /// single-block implementation passes every other test and then fails.
    @Test("matches the FIPS 180-4 vector for a million repetitions")
    func millionCharacterVector() {
        let input = String(repeating: "a", count: 1_000_000)
        #expect(
            Digest.of(input).hexadecimal
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    /// Feeding the same bytes in any number of pieces must produce the same digest, or an
    /// identity would depend on how a caller happened to chunk its input.
    @Test(
        "is unaffected by how the input is chunked",
        arguments: [1, 2, 3, 55, 56, 57, 63, 64, 65, 127, 128, 129]
    )
    func chunkingDoesNotMatter(chunk: Int) {
        let bytes = Array("the quick brown fox jumps over the lazy dog, twice over".utf8)
        var hasher = SHA256()
        for start in stride(from: 0, to: bytes.count, by: chunk) {
            hasher.update(bytes[start..<min(start + chunk, bytes.count)])
        }
        #expect(hasher.finalize() == Digest.of(bytes))
    }

    /// A `Sequence` need not know its own length in advance, and a hasher that asked it
    /// for one would encode a message length that is not the message's.
    ///
    /// This exists because an attempted optimisation did exactly that: it took
    /// `underestimatedCount` as the byte count, which is zero for a sequence generated
    /// lazily. Every existing test still passed, because every call site happened to
    /// hand over an `Array`.
    @Test("counts the bytes it was given, not the bytes a sequence predicted")
    func lengthComesFromTheBytesThemselves() {
        let text = "the quick brown fox"
        var remaining = Array(text.utf8)[...]
        let lazySequence = sequence(state: 0) { (_: inout Int) -> UInt8? in
            guard let next = remaining.first else { return nil }
            remaining = remaining.dropFirst()
            return next
        }
        #expect(lazySequence.underestimatedCount == 0, "the premise of this test")
        #expect(Digest.of(lazySequence) == Digest.of(text))
    }

    @Test("is thirty-two bytes, rendered as sixty-four lowercase hex characters")
    func shape() {
        let digest = Digest.of("abc")
        #expect(digest.bytes.count == 32)
        #expect(digest.hexadecimal.count == 64)
        #expect(digest.hexadecimal.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// The CLI shows a collision-checked prefix; JSON always carries the whole identity.
    @Test("offers a short form that is a prefix of the long one")
    func shortForm() {
        let digest = Digest.of("abc")
        #expect(digest.hexadecimal.hasPrefix(digest.shortForm))
        #expect(digest.shortForm.count == 20)
    }

    @Test("orders deterministically so a catalogue can be sorted")
    func ordering() {
        let digests = ["c", "a", "b"].map(Digest.of)
        #expect(digests.sorted().map(\.hexadecimal) == digests.map(\.hexadecimal).sorted())
    }

    @Test("encodes as its hexadecimal string")
    func codableRoundTrip() throws {
        let digest = Digest.of("abc")
        let json = try JSONTestSupport.canonicalJSON(of: ["d": digest])
        #expect(json == #"{"d":"\#(digest.hexadecimal)"}"#)
        #expect(try JSONTestSupport.decode([String: Digest].self, from: json)["d"] == digest)
    }

    @Test("refuses to decode anything that is not sixty-four hex characters")
    func refusesMalformedHexadecimal() {
        for bad in ["", "zz", String(repeating: "a", count: 63), String(repeating: "a", count: 65)]
        {
            #expect(throws: (any Error).self) {
                try JSONTestSupport.decode(Digest.self, from: "\"\(bad)\"")
            }
        }
    }
}
