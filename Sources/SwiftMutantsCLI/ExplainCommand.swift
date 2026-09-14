// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsReport

/// Says everything known about one mutant.
///
/// A run's summary says a hundred and eighty things survived. That is a number, not a task.
/// The work is one mutant at a time, and this is the command that turns a row in a report
/// into something to do about it.
///
/// It reads the last run's report rather than running anything, so it answers immediately
/// and answers about the run somebody actually watched.
struct ExplainCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Say everything known about one mutant.",
        discussion: """
            Takes the identity a report prints, or enough of the front of it to be \
            unambiguous. Reads the last run's report; it runs nothing.

            A survivor no test reaches and a survivor the tests looked at and missed are \
            different problems with different fixes, and this says which one you have.
            """
    )

    @Argument(help: "The mutant's identity, or enough of the front of it.")
    var mutant: String

    @Option(name: .long, help: "The package the run was about. Defaults to the current one.")
    var packagePath: String?

    func run() async throws {
        let root = URL(filePath: packagePath ?? FileManager.default.currentDirectoryPath)
        guard let report = ReportStore.read(from: ReportStore.location(for: root)) else {
            throw ValidationError(
                """
                nothing has been measured here yet. Run `swift-mutants run` first; this \
                reads what that leaves behind.
                """
            )
        }
        guard let found = Explanation.find(mutant, among: report.mutants) else {
            throw ValidationError(Self.nothingFound(mutant, in: report))
        }
        let ran = found.ran.compactMap {
            report.tests.indices.contains($0) ? report.tests[$0] : nil
        }
        for line in Explanation.of(found, reachedBy: ran, with: report.invocation) {
            print(line)
        }
    }

    /// Why nothing came back, in terms of what was typed.
    ///
    /// Two different problems - nothing matches, or too much does - and a reader can only
    /// act on the right one.
    static func nothingFound(_ typed: String, in report: RunReport) -> String {
        let matching = report.mutants.filter { $0.id.lowercased().hasPrefix(typed.lowercased()) }
        guard matching.count > 1 else {
            return """
                no mutant in the last report starts with \(typed). It measured \
                \(report.mutants.count).
                """
        }
        let names = matching.prefix(5).map { String($0.id.prefix(20)) }.joined(separator: "\n  ")
        return """
            \(matching.count) mutants start with \(typed). Type more of one of these:
              \(names)
            """
    }
}
