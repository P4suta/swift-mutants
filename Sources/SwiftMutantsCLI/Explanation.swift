// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsReport

/// One mutant's whole story, for somebody deciding what to do about it.
///
/// A run's summary says a hundred and eighty things survived. That is a number, not a task.
/// The work is one mutant at a time - what was changed, where, which tests ran and did not
/// notice - and the two kinds of survivor are different problems with different fixes: one
/// wants an assertion, the other wants a test or a deletion. Saying which is most of the
/// value here.
enum Explanation {

    /// How many tests to name before the list stops being something a person reads.
    ///
    /// A mutant reached by four hundred tests is a mutant whose problem is not the list.
    static let namedTests = 20

    /// One mutant, in the words a fix needs.
    static func of(_ mutant: RunReport.Mutant, reachedBy tests: [String]) -> [String] {
        var lines = [
            "\(Self.place(of: mutant))  \(mutant.rule)",
            "  \(mutant.original)  ->  \(mutant.replacement)",
            "  \(mutant.id)",
            "",
        ]
        lines += Self.verdict(of: mutant, reachedBy: tests)
        return lines
    }

    /// Where it is, in the words an editor takes - or in bytes, when the line is unknown.
    ///
    /// A position that was never worked out is said plainly rather than printed as `:0:0`,
    /// which an editor would take somewhere wrong and a reader would believe.
    private static func place(of mutant: RunReport.Mutant) -> String {
        guard let line = mutant.line.value, let column = mutant.column.value else {
            return "\(mutant.path) (bytes \(mutant.span.start)..<\(mutant.span.end))"
        }
        return "\(mutant.path):\(line):\(column)"
    }

    /// What became of it, and what to do about it.
    private static func verdict(
        of mutant: RunReport.Mutant, reachedBy tests: [String]
    ) -> [String] {
        switch mutant.outcome {
        case "killed":
            return ["killed by:"] + Self.listed(mutant.killedBy)
        case "survived" where mutant.testsStarted == 0:
            return [
                "no test reaches this, so nothing could have caught it.",
                "Either it wants a test, or the code wants deleting.",
            ]
        case "survived":
            return [
                "\(mutant.testsStarted) tests ran with this change in and all of them passed.",
                "One of them is where the missing assertion belongs:",
            ] + Self.listed(tests)
        default:
            return ["\(mutant.outcome)."]
        }
    }

    /// A list of tests, cut where it stops being readable.
    private static func listed(_ tests: [String]) -> [String] {
        let shown = tests.prefix(Self.namedTests).map { "  \($0)" }
        guard tests.count > Self.namedTests else { return shown }
        return shown + ["  ... and \(tests.count - Self.namedTests) more"]
    }

    /// The one mutant a person meant, if exactly one answers to what they typed.
    ///
    /// Nothing for a prefix that names two: picking the first would explain a mutant nobody
    /// asked about, and from the outside the two are indistinguishable.
    static func find(_ typed: String, among mutants: [RunReport.Mutant]) -> RunReport.Mutant? {
        let wanted = typed.lowercased()
        let matching = mutants.filter { $0.id.lowercased().hasPrefix(wanted) }
        return matching.count == 1 ? matching.first : nil
    }
}
