// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsReport

/// Saying it where the person who caused it is looking.
///
/// A survivor in a terminal is a survivor somebody has to go and find. The same survivor as
/// a workflow command appears on the line it is about, in the diff that introduced it, in
/// the review somebody is already reading - which is the difference between a report and a
/// thing that gets acted on.
///
/// Two forms, because a code host takes two. A `::warning` line lands on the code; the step
/// summary is the run's own account in markdown, and it is the one that still works for a
/// pull request from a fork, where annotations need a token a fork does not have.
enum Annotations {

    /// How many survivors to name before stopping.
    ///
    /// A code host stops showing annotations after a while of its own accord, so the ones
    /// it does show should be the ones worth showing - and the run says how many it held
    /// back rather than letting the list end without explanation.
    static let most = 10

    /// One line per survivor, in the form a code host reads out of a log.
    static func workflowCommands(for report: RunReport) -> [String] {
        let survivors = report.mutants.filter { $0.outcome == "survived" }
        guard !survivors.isEmpty else { return [] }

        var lines = survivors.prefix(Self.most).map { mutant in
            let place = [
                "file=\(mutant.path)",
                "line=\(mutant.line.value ?? 1)",
                "col=\(mutant.column.value ?? 1)",
                "title=Surviving mutant",
            ].joined(separator: ",")
            return "::warning \(place)::\(Self.escaped(Self.message(of: mutant)))"
        }
        if survivors.count > Self.most {
            lines.append(
                "::notice::\(survivors.count - Self.most) more survived; the whole list is in "
                    + "the run's report.")
        }
        return lines
    }

    /// What one survivor says.
    static func message(of mutant: RunReport.Mutant) -> String {
        let kind =
            mutant.testsStarted == 0
            ? "No test reaches it, so nothing could have caught it."
            : "\(mutant.testsStarted) tests ran with it and all of them passed."
        return "\(mutant.original) -> \(mutant.replacement) (\(mutant.rule)) survived. \(kind)"
    }

    /// Text that cannot end the command it is in.
    ///
    /// A newline ends a workflow command, so anything with one in it would make the rest of
    /// the message the log's problem instead of the message's. The percent has to go first
    /// or it would escape the escapes.
    static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// The run's own account, in markdown, for a step summary.
    static func stepSummary(for report: RunReport) -> String {
        let summary = report.summary
        let survivors = report.mutants.filter { $0.outcome == "survived" }
        var lines = [
            "### swift-mutants",
            "",
            "| score | of covered code | killed | survived | unreached | rejected |",
            "| --- | --- | --- | --- | --- | --- |",
            "| \(Self.percentage(summary.score.value)) "
                + "| \(Self.percentage(summary.scoreOfCoveredCode.value)) "
                + "| \(summary.killed) | \(summary.survived) | \(summary.uncovered) "
                + "| \(summary.rejected) |",
            "",
        ]
        guard !survivors.isEmpty else {
            return (lines + ["Nothing survived."]).joined(separator: "\n")
        }

        lines += [
            "| where | change | rule | |",
            "| --- | --- | --- | --- |",
        ]
        lines += survivors.prefix(Self.most).map { mutant in
            let place = "\(mutant.path):\(mutant.line.value ?? 1):\(mutant.column.value ?? 1)"
            let kind = mutant.testsStarted == 0 ? "no test reaches it" : "nothing noticed"
            return "| `\(place)` | `\(mutant.original) -> \(mutant.replacement)` "
                + "| \(mutant.rule) | \(kind) |"
        }
        if survivors.count > Self.most {
            lines += ["", "\(survivors.count - Self.most) more survived."]
        }
        return lines.joined(separator: "\n")
    }

    /// Whether anything here reads workflow commands.
    ///
    /// Asked of the environment rather than of a flag, because it is a fact about where the
    /// run is rather than a preference: the commands are a syntax a code host reads, and in
    /// a terminal they are noise.
    static func wanted(in environment: [String: String]) -> Bool {
        environment["GITHUB_ACTIONS"] == "true"
    }

    /// Where the step summary goes, if anywhere.
    static func summaryFile(in environment: [String: String]) -> URL? {
        guard let path = environment["GITHUB_STEP_SUMMARY"], !path.isEmpty else { return nil }
        return URL(filePath: path)
    }

    /// A fraction as a percentage, or as the absence of one.
    static func percentage(_ fraction: Double?) -> String {
        guard let fraction else { return "N/A" }
        let hundredths = Int((fraction * 10000).rounded())
        return "\(hundredths / 100).\(hundredths % 100 < 10 ? "0" : "")\(hundredths % 100)%"
    }
}
