// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import SwiftMutantsCore

/// Where a run's account of itself is kept after the run is over.
///
/// A mutation run takes long enough that nobody runs it again to look something up, so the
/// report has to outlive the terminal it scrolled past - `explain` reads it, and so does
/// anything that wants to know what the last run found.
///
/// It is kept outside the repository. The first rule of this tool is that the workspace it
/// was pointed at is only ever read, and a report written into somebody's tree would be the
/// tool changing the thing it was measuring - and appearing in their diff.
public enum ReportStore {

    /// Where a package's latest report lives.
    ///
    /// Keyed by where the package is, so two of them do not overwrite each other's answers.
    /// The name is a digest rather than a path so that it is a filename on every platform.
    public static func location(for package: URL) -> URL {
        let root =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = DigestBuilder()
            .adding("swift-mutants-package")
            .adding(package.standardizedFileURL.path)
            .finalize()
        return
            root
            .appending(path: "swift-mutants")
            .appending(path: "report-\(name.hexadecimal).json")
    }

    /// Writes a report, making the directory it lives in if it is not there.
    public static func write(_ report: RunReport, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RunReport.encoded(report).write(to: file)
    }

    /// The report kept there, or nothing.
    ///
    /// Nothing there means nobody has run it yet, which the command that asks has to be
    /// able to say rather than fail on. A file it cannot read is the same answer: a report
    /// half-written by an interrupted run is not a smaller report, it is a wrong one.
    public static func read(from file: URL) -> RunReport? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(RunReport.self, from: data)
    }
}
