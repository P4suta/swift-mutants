// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public import Foundation
import SwiftMutantsCore

/// Who owns a temporary directory, and what becomes of the ones nobody does.
///
/// A run happens inside a copy of somebody's package, and that copy holds a whole build
/// directory - hundreds of megabytes for a package with dependencies. The copy is deleted
/// when the run ends, and a run that does not end is exactly the interesting case: an
/// interrupt, a deadline, a crash, somebody closing the terminal. Nine gigabytes of them
/// accumulated on one machine in one afternoon of developing this tool.
///
/// So each run writes down that the directory is its own, and each run clears up after the
/// ones whose owner is no longer running. Every rule here is about the one mistake that
/// matters - deleting a directory a live run is working in - so it removes only what it can
/// prove is abandoned and leaves everything else, including everything it cannot read.
public enum TempOwner {

    /// The file that says who a directory belongs to.
    public static let markerName = ".swift-mutants-owner"

    /// The prefix every directory this tool makes for itself carries.
    ///
    /// The temporary directory is shared with the whole machine, and a sweep that looked at
    /// anything else would be a tool deciding what somebody else's files are for.
    public static let prefix = "swift-mutants-"

    /// Writes down that `directory` belongs to this process.
    public static func claim(_ directory: URL, by owner: Int32 = getpid()) throws {
        let marker = "\(owner)\n\(Version.current)\n"
        try Data(marker.utf8).write(to: directory.appending(path: Self.markerName))
    }

    /// Who a directory belongs to, if it says.
    ///
    /// Nothing for a directory with no marker, and nothing for one whose marker cannot be
    /// read as a process - a marker half-written by a run that died mid-claim names nobody,
    /// and guessing is the one thing this must not do.
    public static func owner(of directory: URL) -> Int32? {
        guard
            let text = try? String(
                contentsOf: directory.appending(path: Self.markerName), encoding: .utf8),
            let first = text.split(separator: "\n").first,
            let owner = Int32(first),
            owner > 0
        else {
            return nil
        }
        return owner
    }

    /// Removes every directory in `parent` this tool made and nothing is running in.
    ///
    /// - Parameters:
    ///   - parent: where this tool makes its temporary directories.
    ///   - keeping: a directory never to remove, whatever its marker says - the one the
    ///     caller is about to work in.
    /// - Returns: how many were removed.
    @discardableResult
    public static func sweep(in parent: URL, besides keeping: URL?) -> Int {
        guard
            let found = try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil)
        else {
            return 0
        }
        let kept = keeping?.standardizedFileURL.path
        var removed = 0
        for directory in found where directory.lastPathComponent.hasPrefix(Self.prefix) {
            guard directory.standardizedFileURL.path != kept,
                let owner = Self.owner(of: directory),
                !Self.isRunning(owner)
            else {
                continue
            }
            guard (try? FileManager.default.removeItem(at: directory)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    /// Whether a process still exists.
    ///
    /// `kill(pid, 0)` sends nothing and reports whether it could have. `EPERM` means the
    /// process is there and belongs to somebody else, which is still there.
    static func isRunning(_ owner: Int32) -> Bool {
        if kill(owner, 0) == 0 { return true }
        return errno == EPERM
    }
}
