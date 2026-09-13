// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A SHA-256 digest: thirty-two bytes that name a piece of content.
///
/// Everything swift-mutants identifies is identified this way — a file's contents, a
/// catalogue, a workspace, and above all a mutant. The value is a name, never a
/// credential; see ``SHA256`` for why the hash is implemented in this module rather than
/// imported.
public struct Digest: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// The thirty-two bytes of the digest.
    public let bytes: [UInt8]

    /// How many hexadecimal characters the short form carries.
    ///
    /// Twenty is what the sibling projects display, and it is short enough to paste and
    /// long enough that a collision inside one catalogue is not a thing that happens. The
    /// catalogue checks for one anyway and refuses rather than overwriting, because
    /// "unlikely" is not an answer a tool should give about its own identifiers.
    public static let shortFormLength = 20

    /// Wraps bytes already known to be a digest.
    ///
    /// Not public: the only way to obtain a `Digest` from outside is to compute one or to
    /// decode one, and both check the width.
    init(unchecked bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The digest of a byte sequence.
    public static func of(_ bytes: some Sequence<UInt8>) -> Self {
        var hasher = SHA256()
        hasher.update(bytes)
        return hasher.finalize()
    }

    /// The digest of a string's UTF-8 encoding.
    ///
    /// UTF-8 because that is the encoding every byte offset in this tool is measured in;
    /// hashing some other representation would make an identity disagree with the span it
    /// is attached to.
    public static func of(_ text: String) -> Self {
        of(text.utf8)
    }

    /// The full digest as sixty-four lowercase hexadecimal characters.
    public var hexadecimal: String {
        var text = ""
        text.reserveCapacity(64)
        for byte in bytes {
            text.append(Self.hexDigits[Int(byte >> 4)])
            text.append(Self.hexDigits[Int(byte & 0x0f)])
        }
        return text
    }

    /// The prefix the CLI displays. JSON always carries the whole identity.
    public var shortForm: String {
        String(hexadecimal.prefix(Self.shortFormLength))
    }

    /// The full digest, so that interpolating one never abbreviates it by accident.
    public var description: String { hexadecimal }

    /// Orders by bytes, so a catalogue sorts the same way on every machine.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.bytes, rhs.bytes) where left != right {
            return left < right
        }
        return false
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")
}

extension Digest: Codable {
    /// Encodes as the hexadecimal string, so a report is readable and diffable.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexadecimal)
    }

    /// Decodes sixty-four hexadecimal characters, and refuses anything else.
    ///
    /// A digest of the wrong width, or with a character that is not a hexadecimal digit,
    /// is not a digest that any run produced. Accepting it would let a hand-edited
    /// expectation or a truncated report name a mutant that cannot exist.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard text.count == 64 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "a digest is 64 hexadecimal characters; this one has \(text.count)"
                )
            )
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var high: UInt8?
        for character in text {
            guard let value = character.hexDigitValue, value < 16, !character.isUppercase else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription:
                            "'\(character)' is not a lowercase hexadecimal digit"
                    )
                )
            }
            if let first = high {
                bytes.append(first << 4 | UInt8(value))
                high = nil
            } else {
                high = UInt8(value)
            }
        }
        self.init(unchecked: bytes)
    }
}
