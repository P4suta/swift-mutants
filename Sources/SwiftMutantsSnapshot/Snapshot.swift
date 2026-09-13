// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#if canImport(Darwin)
import Darwin
#endif

public import Foundation
public import SwiftMutantsCore

/// A disposable copy of somebody's package.
///
/// The first invariant of this tool rests here: discovery reads the tree a run was pointed
/// at, and every build, edit and test happens in this copy instead. That is what makes it
/// safe to point swift-mutants at a repository somebody is in the middle of working in, and
/// what makes a failed run leave a working tree exactly as it found it.
public struct Snapshot: Sendable {

    /// Where the copy is.
    public let root: URL

    /// What was copied.
    public let manifest: SnapshotManifest

    /// Directories that are never source, wherever they appear.
    ///
    /// Copying them is pointless, and a package with a package inside it has a `.build` at
    /// every level. None of these names can be a source directory, so excluding them
    /// everywhere costs nothing.
    public static let excludedEverywhere: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", ".index-build",
    ]

    /// Directories excluded only at the root.
    ///
    /// The report directory grows *while* a run digests the tree, so a run that copied it
    /// would report drift it had caused itself - a diagnostic failing the run it is a
    /// diagnostic of. Only at the root, because `Sources/Reporting/reports` is a name
    /// somebody may legitimately have given to source.
    public static let excludedAtRoot: Set<String> = ["reports"]

    /// Copies a tree, refusing anything a copy cannot faithfully hold.
    public static func create(of source: URL, at destination: URL) throws -> Self {
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            guard existing.isEmpty else {
                throw SnapshotError(
                    "\(destination.path) already holds something; a snapshot is a fresh copy"
                )
            }
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var entries: [SnapshotManifest.Entry] = []
        try walk(source, relativeTo: []) { relative, file, attributes in
            guard let path = WorkspaceRelativePath(relative.joined(separator: "/")) else {
                throw SnapshotError("'\(relative.joined(separator: "/"))' is not a usable path")
            }
            let target = destination.appending(path: path.rendered)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let bytes = try Data(contentsOf: file)
            try bytes.write(to: target)

            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            let isExecutable = permissions & 0o111 != 0
            if isExecutable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: permissions)],
                    ofItemAtPath: target.path
                )
            }
            entries.append(
                SnapshotManifest.Entry(
                    path: path,
                    digest: Digest.of(bytes),
                    isExecutable: isExecutable
                )
            )
        }

        return Self(root: destination, manifest: SnapshotManifest(entries))
    }

    /// Which paths in the copy no longer match the manifest.
    ///
    /// A test that writes into the package directory it runs in would make every later
    /// mutant a measurement of a different program, and nothing else in the pipeline would
    /// notice. This is the gate that does: a changed file, one that appeared, and one that
    /// vanished are all reported.
    public func drift() throws -> [WorkspaceRelativePath] {
        var seen: Set<WorkspaceRelativePath> = []
        var drifted: [WorkspaceRelativePath] = []
        let expected = Dictionary(
            manifest.entries.map { ($0.path, $0.digest) },
            uniquingKeysWith: { first, _ in first }
        )

        try Self.walk(root, relativeTo: []) { relative, file, _ in
            guard let path = WorkspaceRelativePath(relative.joined(separator: "/")) else { return }
            seen.insert(path)
            guard let wanted = expected[path] else {
                drifted.append(path)
                return
            }
            if try Digest.of(Data(contentsOf: file)) != wanted {
                drifted.append(path)
            }
        }
        for path in expected.keys where !seen.contains(path) {
            drifted.append(path)
        }
        return drifted.sorted()
    }

    /// Walks a tree, refusing anything that is not a plain file or a directory.
    ///
    /// Refused rather than skipped, and that is the decision. A link that leaves the tree
    /// makes the copy a copy of something else; one that stays inside makes two paths into
    /// one file, so an edit for one mutant would silently change a second place. A device, a
    /// socket or a pipe cannot be copied at all. None of those is a thing to discover
    /// halfway through a run, so the walk stops at the first one and names it.
    static func walk(
        _ directory: URL,
        relativeTo prefix: [String],
        _ visit: ([String], URL, [FileAttributeKey: Any]) throws -> Void
    ) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw SnapshotError("cannot read \(directory.path): \(error)")
        }

        for name in names.sorted() {
            if Self.excludedEverywhere.contains(name) { continue }
            if prefix.isEmpty, Self.excludedAtRoot.contains(name) { continue }
            let child = directory.appending(path: name)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: child.path)
            } catch {
                throw SnapshotError("cannot read \(child.path): \(error)")
            }

            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                try walk(child, relativeTo: prefix + [name], visit)
            case .typeRegular:
                try visit(prefix + [name], child, attributes)
            case .typeSymbolicLink:
                throw SnapshotError(
                    """
                    \((prefix + [name]).joined(separator: "/")) is a symbolic link. A snapshot \
                    refuses one rather than following it: a link out of the tree would make \
                    the copy a copy of something else, and a link inside it would make two \
                    paths one file, so an edit for one mutant would change a second place.
                    """
                )
            default:
                throw SnapshotError(
                    """
                    \((prefix + [name]).joined(separator: "/")) is not a plain file, so it \
                    cannot be copied faithfully.
                    """
                )
            }
        }
    }
}
