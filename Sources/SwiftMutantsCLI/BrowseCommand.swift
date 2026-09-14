// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsReport
import SwiftMutantsTUI

/// Walks the survivors of the last run.
///
/// A run prints its survivors and stops there, which is right for a log and wrong for the
/// half hour afterwards: the work is one mutant at a time, and `explain <id>` means copying
/// an identity out of a scrollback for each one. This is the same list with somewhere to
/// stand in it.
///
/// It reads the last run's report and runs nothing, so it answers immediately and answers
/// about the run somebody actually watched.
struct BrowseCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "browse",
        abstract: "Walk the survivors of the last run.",
        discussion: """
            Up and down, or k and j. Enter opens one and shows everything known about it; \
            q goes back, and again to leave.

            Needs a terminal. Into a pipe it prints the same list once and stops, which is \
            what a log can hold.
            """
    )

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
        let browser = Browser(rows: Self.rows(of: report))
        guard Ambient.isTerminal else {
            // A pipe gets the list once. Raw mode on something that is not a terminal would
            // be a command that hangs waiting for keys nobody is typing.
            for line in browser.frame(width: 100, height: browser.rows.count + 2) {
                print(line)
            }
            return
        }
        try Terminal.walk(browser)
    }

    /// The survivors of a report, flattened into what a list and a page need.
    ///
    /// Survivors only. A killed mutant is not a thing to walk through - whoever reads this
    /// already has the test that caught it, which beats anything a browser could show them.
    static func rows(of report: RunReport) -> [Browser.Row] {
        report.mutants.filter { $0.outcome == "survived" }.map { mutant in
            let ran = mutant.ran.compactMap {
                report.tests.indices.contains($0) ? report.tests[$0] : nil
            }
            return Browser.Row(
                identity: mutant.id,
                place: Explanation.place(of: mutant),
                rule: mutant.rule,
                change: "\(mutant.original)  ->  \(mutant.replacement)",
                story: Explanation.of(mutant, reachedBy: ran, with: report.invocation)
            )
        }
    }
}
