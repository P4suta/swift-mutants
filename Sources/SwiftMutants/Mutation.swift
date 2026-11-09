// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover

/// One source edit discovered from a Swift file.
public struct Mutation: Sendable, Hashable, Encodable {
    let mutant: Mutant
    let sourceDigest: Digest
    /// The source line, starting at one.
    public let line: Int
    /// The UTF-8 byte column, starting at one.
    public let column: Int

    /// The full identity used by the command-line tool.
    public var id: String { mutant.identity.rendered }

    /// The normalized workspace-relative source path.
    public var path: String { mutant.path.rendered }

    /// The mutation operator's name.
    public var rule: String { mutant.rule.name }

    /// The half-open range of UTF-8 byte offsets to replace.
    public var byteRange: Range<Int> { mutant.span.start..<mutant.span.end }

    /// The source text at the mutation's byte range.
    public var original: String { mutant.original }

    /// The replacement text.
    public var replacement: String { mutant.replacement }

    /// Finds mutations using the CLI's default operators without reading files or compiling.
    /// The path identifies the source and must name a workspace-relative Swift file.
    /// The compiler must still check whether each mutation typechecks.
    public static func discover(in source: String, at path: String) throws(MutationError) -> [Self]
    {
        guard let relativePath = WorkspaceRelativePath(path), relativePath.isSwift,
            !path.utf8.contains(0)
        else {
            throw .invalidPath(path)
        }
        let discovery = Discover.candidates(in: source, at: relativePath)
        let lines = LineIndex(source)
        return discovery.candidates.map { candidate in
            Self(
                mutant: Mutant(
                    path: discovery.path,
                    enclosingDeclaration: candidate.enclosingDeclaration,
                    rule: candidate.rule,
                    span: candidate.span,
                    sourceDigest: discovery.sourceDigest,
                    original: candidate.original,
                    replacement: candidate.replacement
                ),
                sourceDigest: discovery.sourceDigest,
                position: lines.position(of: candidate.span.start)
            )
        }
    }

    init(mutant: Mutant, sourceDigest: Digest, position: SourcePosition?) {
        self.mutant = mutant
        self.sourceDigest = sourceDigest
        self.line = position?.line ?? 1
        self.column = position?.column ?? 1
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, rule, byteRange, sourceDigest, original, replacement, line, column
    }

    /// Encodes identity, source location, digest, and edit bytes.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(rule, forKey: .rule)
        try container.encode(
            ["start": byteRange.lowerBound, "end": byteRange.upperBound],
            forKey: .byteRange
        )
        try container.encode(sourceDigest.hexadecimal, forKey: .sourceDigest)
        try container.encode(original, forKey: .original)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(line, forKey: .line)
        try container.encode(column, forKey: .column)
    }

    /// Returns a copy of the source with only the selected mutation applied.
    /// Throws `MutationError.sourceChanged` if any source byte changed after discovery.
    public func applying(to source: String) throws(MutationError) -> String {
        guard Digest.of(source) == sourceDigest else {
            throw .sourceChanged(path: path)
        }
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(byteRange, with: replacement.utf8)
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// An input error during mutation discovery or editing.
public enum MutationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The path doesn't identify a workspace-relative Swift file.
    case invalidPath(String)

    /// The source bytes differ from the input used for discovery.
    case sourceChanged(path: String)

    /// The input error and its source path.
    public var description: String {
        switch self {
        case .invalidPath(let path):
            "Expected a workspace-relative Swift file path: \(path)"
        case .sourceChanged(let path):
            "Source changed after mutation discovery: \(path)"
        }
    }
}
