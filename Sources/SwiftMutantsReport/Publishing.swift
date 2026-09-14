// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import SwiftMutantsConfig
import SwiftMutantsCore

/// Writing the documents a run was asked for.
///
/// These go into the repository, which is the one place this tool otherwise never writes.
/// That is deliberate and it is the user's decision: a report is something they commit,
/// publish, or hand to a code host, and it is no use to them in a cache directory they
/// cannot find. Nothing is written unless it was asked for.
public enum Publishing {

    /// Where the documents go, relative to the package.
    public static let directory = "reports/mutation"

    /// What each format is called there.
    public static func name(of format: ReportFormat) -> String {
        switch format {
        case .json: "mutation.json"
        case .html: "mutation.html"
        case .sarif: "mutation.sarif"
        }
    }

    /// Writes each document asked for, and says where each went.
    ///
    /// - Parameters:
    ///   - report: the run's own account of itself.
    ///   - formats: what to write. Nothing is written for an empty set, including the
    ///     directory: a tool that made an empty folder in somebody's repository for a thing
    ///     they did not ask for would be a tool they stop running.
    ///   - root: the package the run was about, which is where the sources are read from.
    /// - Returns: the files written, in a fixed order.
    /// - Throws: whatever the file system said, when a document could not be written. A
    ///   run that answered and then could not save its answer is worth saying out loud
    ///   rather than swallowing.
    @discardableResult
    public static func write(
        _ report: RunReport, formats: Set<ReportFormat>, into root: URL
    ) throws -> [URL] {
        guard !formats.isEmpty else { return [] }
        let home = root.appending(path: Self.directory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let sources = Self.sources(of: report, in: root)
        var written: [URL] = []
        for format in ReportFormat.allCases where formats.contains(format) {
            let file = home.appending(path: Self.name(of: format))
            switch format {
            case .json:
                try StrykerReport.encoded(StrykerReport(of: report, sources: sources))
                    .write(to: file)
            case .sarif:
                try SarifReport.encoded(SarifReport(of: report)).write(to: file)
            case .html:
                try Data(HtmlReport.page(of: report, sources: sources).utf8).write(to: file)
            }
            written.append(file)
        }
        return written
    }

    /// The source of every file that is still what it was when the run read it.
    ///
    /// A report shows the code beside the verdict, which means reading it afterwards - and
    /// a file that changed in between is a file whose lines no longer mean what the verdict
    /// says. It is left out rather than shown, because code beside the wrong verdict is
    /// worse than no code at all.
    static func sources(of report: RunReport, in root: URL) -> [String: String] {
        var found: [String: String] = [:]
        for (path, digest) in report.files {
            guard
                let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8),
                Digest.of(text).hexadecimal == digest
            else {
                continue
            }
            found[path] = text
        }
        return found
    }
}
