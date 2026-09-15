// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A path inside the workspace, normalised, and never absolute.
///
/// Discovery reads the user's own tree while every build, edit and test happens inside a
/// disposable snapshot at a temporary location, so the same file has at least two absolute
/// paths during one run and a third if the checkout ever moves. An identity built from any
/// of them would change for reasons that have nothing to do with the program, silently
/// taking the outcome cache, the recorded expectations and the shard assignment with it.
///
/// The invariant is therefore carried by the type rather than by a rule each call site has
/// to remember: this initialiser is the only way to obtain one, and it refuses anything
/// absolute or anything that climbs out of the workspace.
public struct WorkspaceRelativePath: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// The path's components, with `.` removed and `..` resolved.
    public let components: [String]

    /// The portable spelling: components joined with `/`, on every platform.
    ///
    /// Forward slashes whatever the input used, because an identity computed on Windows
    /// has to equal the one computed on macOS for the same file.
    public var rendered: String { components.joined(separator: "/") }

    /// The portable spelling, with forward slashes.
    public var description: String { rendered }

    /// Whether this names a Swift file.
    ///
    /// A target holding C is a `library` target like any other, so its `.c` and `.h` files
    /// arrive wherever its Swift does. Parsed as Swift they are not an error, and that is
    /// the trap: the parser accepts them and produces findings.
    ///
    /// It had two faces, and the one anybody could see was the harmless one. The visible
    /// half was noise - swift-syntax reads `#define` and `#include` as macro expansions,
    /// which this tool skips, so a package vendoring Argon2 got 79 per-line skips for
    /// somebody else's preprocessor, reported as findings about their own code. Its author
    /// reported that, and grepped them out.
    ///
    /// The half nobody could see was fatal. C and Swift share operator syntax, so
    /// `return a < b;` in `blake2.c` is a perfectly good `lt-to-le` site to a parser that
    /// does not know what it is reading - 365 of them in that one package. Those were
    /// instrumented: Swift ternary guards written into `.c` files that no C compiler
    /// accepts. Validation then failed, could not attribute the errors to anything, and
    /// fell to bisection - one full package build per step, cornering several hundred
    /// refusals. From outside it was a run that printed one progress line and stopped after
    /// forty minutes.
    ///
    /// By extension rather than by sniffing the contents, because the extension is what
    /// the compiler decides by too.
    public var isSwift: Bool { rendered.hasSuffix(".swift") }

    /// Normalises a path, or refuses it.
    ///
    /// Refused: anything absolute, anything that would climb above the workspace root, and
    /// anything that names nothing once `.` components are dropped. A path that escapes is
    /// refused rather than clamped, because clamping would silently turn a reference to
    /// somebody else's file into a reference to one of ours.
    public init?(_ text: String) {
        // A backslash is a separator too: a path arriving from a Windows toolchain is
        // normalised rather than refused, since refusing it would make the tool unusable
        // there for no gain in safety. Both separators are handled by splitting on either,
        // rather than by rewriting the string, which keeps this module free of Foundation.
        func isSeparator(_ character: Character) -> Bool { character == "/" || character == "\\" }

        guard let first = text.first else { return nil }
        guard !isSeparator(first) else { return nil }
        // A drive-qualified path is absolute even without a leading separator.
        if text.count >= 2, text[text.index(after: text.startIndex)] == ":" { return nil }

        var resolved: [String] = []
        for component in text.split(whereSeparator: isSeparator) {
            switch component {
            case ".":
                continue
            case "..":
                guard !resolved.isEmpty else { return nil }
                resolved.removeLast()
            default:
                resolved.append(String(component))
            }
        }
        guard !resolved.isEmpty else { return nil }
        self.components = resolved
    }

    /// Orders component by component, so a catalogue sorts identically everywhere.
    ///
    /// Not by the rendered string: `a/b` and `a-b` order differently under the two rules,
    /// and a report that a reader diffs against another machine's should not depend on
    /// which was used.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.components, rhs.components) where left != right {
            return left < right
        }
        return lhs.components.count < rhs.components.count
    }
}

extension WorkspaceRelativePath: Codable {
    /// Encodes as the rendered string, so a report stays readable.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rendered)
    }

    /// Decodes through the same normalisation, refusing what the initialiser would refuse.
    ///
    /// A stored report is read back by a later phase and by `report merge`. Accepting an
    /// absolute path here would let a hand-edited document point the tool at a file
    /// outside the tree it is measuring.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let path = WorkspaceRelativePath(text) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "'\(text)' is not a workspace-relative path: it is absolute, escapes the workspace, or names nothing"
                )
            )
        }
        self = path
    }
}
