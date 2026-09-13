// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Names one mutation rule, at one version: `add-to-sub@1`.
///
/// The version is not documentation. It participates in the identity of every mutant the
/// rule produces, so changing what a rule emits changes those identities — which makes the
/// outcome cache miss and any recorded expectation go stale, loudly. Without it, a rule
/// that started emitting different bytes would quietly inherit verdicts that were reached
/// about the bytes it used to emit.
///
/// Names are lowercase kebab-case and nothing else, because the same string appears in
/// configuration, on the command line, in the JSON report and in the fixture corpus, and
/// four spellings of one rule is four places for them to disagree.
public struct RuleIdentifier: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// The rule's name, in lowercase kebab-case.
    public let name: String

    /// The rule's version: a positive integer.
    public let version: Int

    /// The canonical spelling, `name@version`.
    public var rendered: String { "\(name)@\(version)" }

    /// The canonical `name@version` spelling.
    public var description: String { rendered }

    /// Creates an identifier from its parts, or refuses them.
    public init?(_ name: String, version: Int) {
        guard version > 0, Self.isWellFormedName(name) else { return nil }
        self.name = name
        self.version = version
    }

    /// Parses the canonical spelling, or refuses it.
    ///
    /// Exactly one `@`, a well-formed name before it, and a positive decimal with no
    /// leading zero after it. Leading zeros are refused rather than accepted and
    /// normalised, because `add-to-sub@01` and `add-to-sub@1` would otherwise be two
    /// spellings of one identity and a reader would have to know which one a report used.
    public init?(_ spelling: String) {
        let parts = spelling.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let digits = parts[1]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy({ $0.isNumber })
        else {
            return nil
        }
        guard digits.first != "0", let version = Int(digits) else { return nil }
        self.init(String(parts[0]), version: version)
    }

    /// Orders by name, then by version.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name ? lhs.version < rhs.version : lhs.name < rhs.name
    }

    /// Lowercase ASCII letters and digits, in hyphen-separated segments, each non-empty
    /// and each starting with a letter.
    private static func isWellFormedName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let segments = name.split(separator: "-", omittingEmptySubsequences: false)
        guard segments.count >= 1 else { return false }
        for segment in segments {
            guard let first = segment.first, first.isASCII, first.isLowercase, first.isLetter else {
                return false
            }
            guard segment.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) else {
                return false
            }
        }
        return true
    }
}

extension RuleIdentifier: Codable {
    /// Encodes as the canonical spelling.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rendered)
    }

    /// Decodes through the same parser, refusing what the initialiser would refuse.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let rule = RuleIdentifier(text) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "'\(text)' is not a rule identifier: expected a lowercase kebab-case name, '@', and a positive version"
                )
            )
        }
        self = rule
    }
}
