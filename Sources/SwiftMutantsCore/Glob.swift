// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A path pattern, with the meaning pinned here rather than borrowed.
///
/// Which files a run mutates decides which mutants exist, which decides every identity in
/// the catalogue and every cached outcome keyed on one. `**` means different things in
/// different glob libraries, so a pattern whose meaning came from a dependency would let a
/// dependency upgrade silently change a project's mutation score. The engine is therefore
/// written here, and its semantics are held by tests instead of by somebody's changelog.
///
/// The grammar is small on purpose:
///
/// - `/` separates components, on every platform.
/// - `*` matches any run of bytes, including none, **within one component**.
/// - `?` matches exactly one byte, and never a separator.
/// - `**` is a whole component and matches zero or more components.
/// - Everything else matches itself, case sensitively.
///
/// There are no character classes. A `[a-z]` in a pattern is five literal bytes, because
/// every extension to the grammar is another thing two implementations can disagree about.
///
/// Matching is over **UTF-8 bytes** rather than characters. Grapheme breaking depends on
/// the Unicode tables the standard library was built with, so a pattern matched that way
/// could change meaning under a toolchain update; byte semantics cannot. In practice
/// patterns over source paths are ASCII, where the two agree.
public struct Glob: Sendable, Hashable, CustomStringConvertible {

    /// One piece of the pattern between separators.
    private enum Component: Sendable, Hashable {
        /// `**`: zero or more path components.
        case anyComponents
        /// Bytes, possibly with `*` and `?` in them.
        case pattern([UInt8])
    }

    private let components: [Component]

    /// The pattern as it was written.
    public let description: String

    /// Parses a pattern, or refuses it.
    ///
    /// Refused: a pattern that names nothing, and a `**` that is not a whole component.
    /// `a**b` is refused rather than being read as `a*b` or as "anything under a ending in
    /// b", because those are the two readings different implementations pick and a silent
    /// choice between them is exactly what this type exists to prevent.
    public init?(_ pattern: String) {
        var parsed: [Component] = []
        for piece in pattern.split(separator: "/", omittingEmptySubsequences: true) {
            if piece == "**" {
                parsed.append(.anyComponents)
            } else if piece.contains("**") {
                return nil
            } else {
                parsed.append(.pattern(Array(piece.utf8)))
            }
        }
        guard !parsed.isEmpty else { return nil }

        // A trailing `**` must swallow at least one component: `vendor/**` names what is
        // under `vendor`, not a file called `vendor`. Rewriting it to `**/*` says exactly
        // that, and keeps the matcher free of a special case - in the middle of a pattern
        // `**` still matches nothing, which is what lets `a/**/b` match `a/b`.
        if parsed.last == .anyComponents {
            parsed.append(.pattern([UInt8(ascii: "*")]))
        }
        components = parsed
        description = pattern
    }

    /// Whether the pattern matches a workspace-relative path.
    public func matches(_ path: WorkspaceRelativePath) -> Bool {
        matches(components: path.components.map { Array($0.utf8) })
    }

    /// Whether the pattern matches a path spelled as a string.
    ///
    /// The string is split on `/` the same way a ``WorkspaceRelativePath`` is, but it is
    /// not normalised: this overload exists for patterns matched against paths that are
    /// already relative and already clean, such as the ones a diff reports.
    public func matches(_ path: String) -> Bool {
        matches(
            components: path.split(separator: "/", omittingEmptySubsequences: true)
                .map { Array($0.utf8) }
        )
    }

    /// Matches the component list, treating `**` as the only place backtracking is needed.
    ///
    /// The same two-pointer walk the byte matcher uses, one level up: remember where the
    /// last `**` was and how far the path had got, and on a mismatch resume from there with
    /// the `**` having swallowed one more component. That bounds the work at the product
    /// of the two lengths rather than letting it branch.
    private func matches(components path: [[UInt8]]) -> Bool {
        var patternIndex = 0
        var pathIndex = 0
        var lastWildcard: Int?
        var resumeAt = 0

        while pathIndex < path.count {
            if patternIndex < components.count {
                switch components[patternIndex] {
                case .anyComponents:
                    lastWildcard = patternIndex
                    resumeAt = pathIndex
                    patternIndex += 1
                    continue
                case .pattern(let bytes):
                    if Self.matches(bytes: path[pathIndex], against: bytes) {
                        patternIndex += 1
                        pathIndex += 1
                        continue
                    }
                }
            }
            guard let wildcard = lastWildcard else { return false }
            patternIndex = wildcard + 1
            resumeAt += 1
            pathIndex = resumeAt
        }

        // A trailing `**` has nothing left to swallow, which is how `a/**/b` matches `a/b`.
        while patternIndex < components.count, components[patternIndex] == .anyComponents {
            patternIndex += 1
        }
        return patternIndex == components.count
    }

    /// Matches one component's bytes against one component's pattern.
    ///
    /// Iterative with a remembered star rather than recursive. A naive matcher branches at
    /// every `*` and takes time exponential in the number of them against a long
    /// non-matching name; remembering only the most recent star is enough to find a match
    /// if one exists, and bounds the work at `pattern.count * subject.count`.
    private static func matches(bytes subject: [UInt8], against pattern: [UInt8]) -> Bool {
        let star = UInt8(ascii: "*")
        let question = UInt8(ascii: "?")

        var patternIndex = 0
        var subjectIndex = 0
        var lastStar: Int?
        var resumeAt = 0

        while subjectIndex < subject.count {
            if patternIndex < pattern.count {
                let token = pattern[patternIndex]
                if token == star {
                    lastStar = patternIndex
                    resumeAt = subjectIndex
                    patternIndex += 1
                    continue
                }
                if token == question || token == subject[subjectIndex] {
                    patternIndex += 1
                    subjectIndex += 1
                    continue
                }
            }
            guard let star = lastStar else { return false }
            patternIndex = star + 1
            resumeAt += 1
            subjectIndex = resumeAt
        }

        while patternIndex < pattern.count, pattern[patternIndex] == star {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}

/// What a run mutates: what was included, minus what was excluded.
public struct GlobSet: Sendable, Hashable {

    /// Patterns that name what to mutate. Empty means everything.
    public let include: [Glob]

    /// Patterns that name what to leave alone, applied after ``include``.
    public let exclude: [Glob]

    /// Creates a set from the two lists.
    public init(include: [Glob], exclude: [Glob]) {
        self.include = include
        self.exclude = exclude
    }

    /// Whether a path survives both lists.
    ///
    /// Excludes are applied after includes, so a narrow exclusion carves a hole in a broad
    /// inclusion rather than the other way round. An empty include list admits everything,
    /// which is what makes `exclude` usable on its own.
    public func admits(_ path: WorkspaceRelativePath) -> Bool {
        admits(included: include.isEmpty || include.contains { $0.matches(path) }) {
            $0.matches(path)
        }
    }

    /// Whether a path spelled as a string survives both lists.
    public func admits(_ path: String) -> Bool {
        admits(included: include.isEmpty || include.contains { $0.matches(path) }) {
            $0.matches(path)
        }
    }

    private func admits(included: Bool, excludedBy: (Glob) -> Bool) -> Bool {
        included && !exclude.contains(where: excludedBy)
    }
}
