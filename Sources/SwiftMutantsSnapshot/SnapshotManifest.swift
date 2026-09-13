// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsCore

/// What a snapshot holds, and a digest over the whole of it.
///
/// Sorted, because two machines copying the same tree have to agree about what they copied:
/// the digest goes into the outcome cache's key and into the check that a report describes
/// the program it claims to, and a filesystem makes no promise about the order it hands
/// entries over in.
public struct SnapshotManifest: Sendable, Hashable {

    /// One file in the tree.
    public struct Entry: Sendable, Hashable {
        /// Where it is, relative to the root.
        public let path: WorkspaceRelativePath
        /// A digest of its contents.
        public let digest: Digest
        /// Whether it is executable, which a copy has to preserve.
        public let isExecutable: Bool
    }

    /// The files, ordered by path.
    public let entries: [Entry]

    /// A digest over every path and every content digest, in order.
    public let digest: Digest

    /// Builds a manifest from entries in any order.
    public init(_ entries: some Sequence<Entry>) {
        let ordered = entries.sorted { $0.path < $1.path }
        var builder = DigestBuilder().adding("swift-mutants/snapshot-manifest")
        for entry in ordered {
            builder = builder.adding(entry.path.rendered)
                .adding(entry.digest)
                .adding(entry.isExecutable ? 1 : 0)
        }
        self.entries = ordered
        digest = builder.finalize()
    }
}

/// A tree this tool refused to copy, and why.
public struct SnapshotError: Error, Hashable, CustomStringConvertible {

    /// What is wrong, in the words a fix needs.
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}
