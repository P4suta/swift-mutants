// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// What a package holds.
///
/// Asked of the build system rather than worked out by walking directories. A manifest can
/// exclude a file, name its sources explicitly, or put a target somewhere unexpected, and a
/// tool that globbed instead would mutate files the package does not compile - producing
/// mutants that can never be killed because nothing ever runs them.
public struct WorkspaceDescription: Sendable, Hashable {

    /// What the package calls itself.
    public let name: String

    /// Its targets, in the order the build system named them.
    public let targets: [Target]

    /// Describes a package.
    public init(name: String, targets: [Target]) {
        self.name = name
        self.targets = targets
    }

    /// The targets whose sources are worth mutating.
    ///
    /// Test targets are excluded, and that is inherent rather than a recorded skip: mutating
    /// a test would measure whether the tests test themselves.
    public var mutableTargets: [Target] { targets.filter(\.kind.isMutable) }

    /// One target.
    public struct Target: Sendable, Hashable {
        /// What the target is called.
        public let name: String
        /// What kind of target it is.
        public let kind: Kind
        /// Its source files, relative to the workspace root.
        public let sources: [WorkspaceRelativePath]

        /// Describes one target.
        public init(name: String, kind: Kind, sources: [WorkspaceRelativePath]) {
            self.name = name
            self.kind = kind
            self.sources = sources
        }
    }

    /// What a target is for.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case library
        case executable
        case test
        case plugin
        case binary
        case system
        case snippet
        case macro

        /// Whether this tool has any business mutating the target's sources.
        ///
        /// Only code that ships. A test target is excluded because mutating a test measures
        /// whether the tests test themselves; a plugin and a macro because they run at build
        /// time, in a different process, against a different program.
        public var isMutable: Bool {
            switch self {
            case .library, .executable: true
            case .test, .plugin, .binary, .system, .snippet, .macro: false
            }
        }
    }
}

/// A package this tool could not read.
public struct BuildSystemError: Error, Hashable, CustomStringConvertible {
    /// What went wrong, in the words a fix needs.
    public let description: String

    init(_ description: String) { self.description = description }
}
