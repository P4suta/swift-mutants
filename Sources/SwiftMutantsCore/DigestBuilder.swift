// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Hashes a sequence of fields so that the fields cannot run together.
///
/// Every identity in swift-mutants is a digest over several fields: a path, a rule name
/// and version, a byte span, the bytes before and after the edit. Hashing them by plain
/// concatenation would make `("ab", "c")` and `("a", "bc")` the same value — two different
/// mutants sharing an identity, one adopting the other's cached outcome, with nothing in
/// the output saying so.
///
/// So each field is written as an eight-byte big-endian length, a one-byte type tag, then
/// its bytes. The length removes the boundary ambiguity; the tag keeps the string `"42"`
/// from colliding with the number `42`, which matters because a rule name and a byte
/// offset sit next to each other in a mutant's identity.
///
/// The encoding is part of the identity scheme rather than an implementation detail.
/// Changing it changes every mutant ID in every project using the tool, so it is pinned by
/// a test and must be accompanied by a bump of
/// ``SwiftMutantsCore/identitySchemeVersion``.
public struct DigestBuilder: Sendable {

    private var hasher = SHA256()

    /// Creates a builder over no fields.
    public init() {}

    /// One byte that says what kind of field follows.
    private enum Tag: UInt8 {
        case text = 0x73  // 's'
        case integer = 0x69  // 'i'
        case digest = 0x64  // 'd'
        case bytes = 0x62  // 'b'
    }

    /// Appends a text field, encoded as UTF-8.
    public func adding(_ field: String) -> Self {
        appending(.text, Array(field.utf8))
    }

    /// Appends an integer field, as eight bytes big-endian.
    ///
    /// Fixed width rather than decimal, so that a span of `1..<23` cannot be confused with
    /// a span of `12..<3` by their digits running together — which the length prefix would
    /// in fact already prevent, but a fixed width also makes the encoding independent of
    /// how a number happens to be spelled.
    public func adding(_ field: Int) -> Self {
        var bytes = [UInt8]()
        bytes.reserveCapacity(8)
        let pattern = UInt64(bitPattern: Int64(field))
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: pattern >> UInt64(shift)))
        }
        return appending(.integer, bytes)
    }

    /// Appends a digest field.
    public func adding(_ field: Digest) -> Self {
        appending(.digest, field.bytes)
    }

    /// Appends a raw byte field.

    /// Finishes the sequence and returns its digest.
    public consuming func finalize() -> Digest {
        hasher.finalize()
    }

    private func appending(_ tag: Tag, _ payload: [UInt8]) -> Self {
        var copy = self
        var header = [UInt8]()
        header.reserveCapacity(9)
        let length = UInt64(payload.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            header.append(UInt8(truncatingIfNeeded: length >> UInt64(shift)))
        }
        header.append(tag.rawValue)
        copy.hasher.update(header)
        copy.hasher.update(payload)
        return copy
    }
}
