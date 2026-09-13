// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import SwiftMutantsTrace

/// What a failed run leaves behind so that it can be diagnosed without being run again.
///
/// This is what makes a CI failure diagnosable from the artefacts instead of by asking
/// somebody to reproduce it - which, on a run that takes an hour and depends on a machine's
/// load, is asking a great deal.
///
/// The files are written in a fixed order, and the order *is* the marker. ``errorFileName``
/// goes first because it is what makes the directory this tool's; ``completionFileName``
/// goes last because it is what says the directory is finished. A collector that could not
/// tell a finished bundle from a half-written one would eventually take away the account of
/// the crash it was collected for, which is collecting exactly backwards.
public enum DiagnosticsBundle {

    /// Written first: what makes the directory this tool's.
    public static let errorFileName = "error.txt"

    /// Written last: what says the directory is finished.
    public static let completionFileName = "preserved-paths.txt"

    /// Everything a bundle holds.
    public struct Contents: Sendable {

        /// The failure, rendered.
        public let error: String

        /// The typed chain underneath it, outermost first.
        public let errorChain: [String]

        /// The **names** of the environment's variables.
        ///
        /// Names only. A bundle is something people attach to a bug report, and a value
        /// that reached this run would otherwise reach the report.
        public let environmentNames: [String]

        /// The `doctor` table for this machine, as JSON.
        public let doctor: String?

        /// The run's own account, out of the in-memory ring.
        public let trace: [TraceEvent]

        /// The report, if the run got far enough to have one.
        public let report: String?

        /// What `--keep-temp` left on disk, if anything.
        public let preservedPaths: [String]

        /// Assembles a bundle's contents.
        public init(
            error: String,
            errorChain: [String],
            environmentNames: [String],
            doctor: String?,
            trace: [TraceEvent],
            report: String?,
            preservedPaths: [String]
        ) {
            self.error = error
            self.errorChain = errorChain
            self.environmentNames = environmentNames
            self.doctor = doctor
            self.trace = trace
            self.report = report
            self.preservedPaths = preservedPaths
        }
    }

    /// Writes a bundle, in the order that makes it readable half-written.
    ///
    /// A bundle whose *first* write fails leaves no directory at all. An empty directory
    /// carries no marker, so neither the retention nor a manual clean could ever name it,
    /// and it would keep the root it sits in from being removed as well.
    @discardableResult
    public static func write(_ contents: Contents, to directory: URL) throws -> URL {
        let existed = FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Data(contents.error.utf8)
                .write(to: directory.appending(path: errorFileName))
        } catch {
            if !existed { discardIfEmpty(directory) }
            throw error
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(contents.errorChain)
            .write(to: directory.appending(path: "error-chain.json"))
        try Data(contents.environmentNames.sorted().joined(separator: "\n").utf8)
            .write(to: directory.appending(path: "environment.txt"))
        if let doctor = contents.doctor {
            try Data(doctor.utf8).write(to: directory.appending(path: "doctor.json"))
        }
        if !contents.trace.isEmpty {
            var stream = Data()
            for event in contents.trace {
                stream.append(contentsOf: try event.jsonLine())
                stream.append(contentsOf: Data("\n".utf8))
            }
            try stream.write(to: directory.appending(path: "trace.jsonl"))
        }
        if let report = contents.report {
            try Data(report.utf8).write(to: directory.appending(path: "report.json"))
        }

        // Last, always.
        try Data(contents.preservedPaths.joined(separator: "\n").utf8)
            .write(to: directory.appending(path: completionFileName))
        return directory
    }

    /// Removes a directory this call created and then failed to put anything in.
    ///
    /// Only if it is empty, and only if it was not already there. An empty directory
    /// carries no marker, so neither the retention nor a manual clean could ever name it,
    /// and it would keep the root it sits in from being removed as well - but a directory
    /// that already held something is somebody else's, and taking it away because *our*
    /// write failed would be a diagnostic destroying evidence.
    static func discardIfEmpty(_ directory: URL) {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard contents?.isEmpty == true else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Whether a directory holds a bundle that finished being written.
    public static func isComplete(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appending(path: completionFileName).path
        )
    }

    /// Keeps the newest `count` finished bundles and removes the rest.
    ///
    /// An unfinished bundle is never collected. It is either a run still going or the one
    /// that crashed, and the account of a crash is the one a reader most wants; a collector
    /// that took it while keeping ten accounts of runs that went fine would be collecting
    /// exactly backwards.
    ///
    /// Anything in the root that is not a bundle at all - a file somebody put there, a
    /// directory another tool keeps - is left exactly as it was found.
    public static func retain(newest count: Int, in root: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let finished =
            entries
            .filter(isComplete)
            .sorted { left, right in
                let leftDate = Self.modified(left) ?? .distantPast
                let rightDate = Self.modified(right) ?? .distantPast
                return leftDate == rightDate ? left.path > right.path : leftDate > rightDate
            }
        for stale in finished.dropFirst(max(0, count)) {
            try FileManager.default.removeItem(at: stale)
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
