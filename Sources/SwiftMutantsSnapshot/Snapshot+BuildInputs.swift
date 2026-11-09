// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore

extension Snapshot {
    package func recordingCurrentFiles() throws -> Self {
        var entries: [SnapshotManifest.Entry] = []
        try Self.walk(root, relativeTo: []) { components, file, attributes in
            guard let path = WorkspaceRelativePath(components.joined(separator: "/")) else {
                throw SnapshotError("Invalid snapshot path")
            }
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            entries.append(
                SnapshotManifest.Entry(
                    path: path,
                    digest: try Digest.of(Data(contentsOf: file)),
                    isExecutable: permissions & 0o111 != 0
                )
            )
        }
        return Self(root: root, manifest: SnapshotManifest(entries))
    }
}
