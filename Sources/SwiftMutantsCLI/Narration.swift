// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsValidate

/// Every word a run says, as a value.
///
/// The narration is the only part of this tool most people ever read, and until now it was
/// spelled inline next to the `print` that emitted it - which made it the one surface with
/// no test at all. Separating what to say from saying it makes each line something a test
/// can hold: a run's account of itself is part of the product, not a side effect of it.
///
/// Nothing here does any I/O, takes a clock, or depends on which worker finished first.
/// Given the same stage it returns the same string, so two runs of the same package narrate
/// themselves identically.
enum Narration {

    /// What each phase says, or nothing for the ones that say it themselves.
    static func line(for stage: RunStage) -> String? {
        switch stage {
        case .snapshotting: "copying the package"
        case .discovering: "reading the sources"
        case .priming: "building your package as you wrote it, once"
        case .instrumenting(let files, let mutants):
            "instrumenting \(mutants) mutants across \(files) files"
        case .proving: "proving every mutant is in the tree"
        case .building: "building the tests, once"
        case .baseline: "running the tests with nothing awake"
        case .validating(let step): validating(step)
        default: measurement(for: stage)
        }
    }

    /// One line for each step of validation.
    ///
    /// A person watching twenty silent minutes cannot tell a second round from a hang, and
    /// the difference matters: one is progress and the other is a bug.
    ///
    /// "Asking" rather than "building", because a round is usually not a build any more: it
    /// is every module of the package lowered at once, separately, against the interfaces
    /// the first build produced. It falls back to a build when the plan cannot be read, and
    /// a word that was true of only one of those would be a lie half the time.
    static func validating(_ step: Validator.Progress) -> String {
        switch step {
        case .compiling(let round, let mutants):
            round == 1
                ? "asking the compiler about all \(mutants) mutants at once"
                : "  asking again, \(mutants) left"
        case .refused(_, let count):
            "  the compiler refused \(count)"
        case .halving(let mutants, let unplaceable):
            "  the compiler would not say which, so halving \(mutants) mutants"
                + (unplaceable.map {
                    "\n  it said: \($0.file):\($0.position): \($0.message)"
                } ?? "")
        }
    }

    /// The lines that carry a number somebody will want to reason about.
    static func measurement(for stage: RunStage) -> String? {
        switch stage {
        case .calibrated(let budget):
            "  giving each mutant \(budget.seconds) seconds, from how long that took"
        case .probing(let tests): "asking each of \(tests) tests what it reaches"
        case .covered(let uncovered, let average):
            "  nothing reaches \(uncovered) of them; the rest face \(oneDecimal(average)) "
                + "tests each, not the whole suite"
        case .recalled(let known, let total):
            "  \(known) of \(total) had not changed since last time and were not asked again"
        case .unmeasured(let tests):
            "  \(tests) of them did not finish, so every mutant is offered them"
        case .scoped(let reference, let files):
            files == 0
                ? "nothing has changed since \(reference)"
                : "measuring only what changed since \(reference): \(files) files"
        case .remembered(let known, let total):
            "\(known) of \(total) were answered by an earlier run and are not run again"
        case .running(let total, let processes):
            processes == total
                ? "running \(total) mutants"
                : "running \(total) mutants in \(processes) processes"
        default: nil
        }
    }

    /// One survivor, in the words a fix needs: where it is, what it did, what to type.
    ///
    /// Everything a reader needs to act, on one line. A list of file names and rule names
    /// sends somebody hunting through a file for the thing this already knows - and the
    /// identity is there because `explain` takes it.
    ///
    /// A file with no line index still gets a usable row, named by the file alone rather
    /// than by an invented `:0:0` that an editor would take somewhere wrong.
    static func describe(_ result: MutantResult, at index: LineIndex?) -> String {
        let place =
            index?.position(of: result.span.start).map { "\(result.path):\($0)" }
            ?? "\(result.path)"
        return [
            place,
            result.identity.shortForm,
            result.rule.name,
            "\(result.original) -> \(result.replacement)",
        ].joined(separator: "  ")
    }

    /// How a finished run accounts for itself, one line at a time.
    ///
    /// Survivors are split in two, because they are different news and want different work.
    /// A mutant no test reaches is usually the cheaper thing to deal with - often by
    /// deleting the code rather than by writing an assertion - so it is listed first and
    /// separately.
    static func summary(of outcome: RunOutcome) -> [String] {
        let summary = outcome.summary
        let survivors = outcome.results.filter { $0.verdict.outcome == .survived }
        let unreached = survivors.filter { $0.verdict.startedTests.isEmpty }
        let unnoticed = survivors.filter { !$0.verdict.startedTests.isEmpty }

        var lines: [String] = []
        if !unreached.isEmpty {
            lines +=
                ["", "no test reaches these:"]
                + unreached.map { "  \(describe($0, at: outcome.positions[$0.path]))" }
        }
        if !unnoticed.isEmpty {
            lines +=
                ["", "these ran and nothing noticed:"]
                + unnoticed.map { "  \(describe($0, at: outcome.positions[$0.path]))" }
        }
        lines += [
            "",
            [
                "\(summary.killed) killed",
                "\(summary.survived) survived (\(summary.uncovered) of them unreached)",
                "\(summary.rejected) rejected",
                "\(summary.timedOut) timed out",
                "\(summary.errored) errored",
            ].joined(separator: "  "),
            "score \(summary.score.rendered)"
                + "  of covered code \(summary.score.renderedForCoveredCode)",
        ]
        return lines
    }

    /// How to turn a list of survivors into something to do.
    ///
    /// Printed only when there is something to explain. A tool that told somebody to run a
    /// command about nothing would be teaching them to ignore its last line.
    static func explainable(_ survivors: Int) -> String {
        survivors == 0
            ? "nothing survived."
            : "swift-mutants explain <id> says everything known about one of them."
    }

    /// Where everything known about a failure was written down.
    ///
    /// Said, because a bundle nobody was told about is a bundle nobody has - and the moment
    /// somebody needs it is the moment the run that could have made it is over.
    static func diagnosed(_ directory: URL) -> String {
        "what this run did is written down at \(directory.path)"
    }

    /// What was cleared up before this run started.
    ///
    /// Said rather than done quietly: deleting hundreds of megabytes of somebody's disk is
    /// a thing to mention, and a reader who did not know these were piling up should find
    /// out from the tool that made them.
    static func swept(_ count: Int) -> String {
        count == 1
            ? "cleared up 1 copy left behind by a run that was interrupted"
            : "cleared up \(count) copies left behind by runs that were interrupted"
    }

    /// Where the copy a run happened in was left.
    ///
    /// Printed rather than merely not deleted: a path nobody was told about is the same as
    /// no path, and the person reading has a failure in front of them and nowhere to look.
    static func kept(_ workspace: URL) -> String {
        "the copy is kept at \(workspace.path)"
    }

    /// A number to one decimal place, without reaching for a variadic C function.
    ///
    /// `String(format:)` is `vsnprintf` underneath, which a package built with
    /// -strict-memory-safety will not let through unmarked - and marking it would be
    /// claiming a safety argument for printing a number.
    static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(abs(tenths % 10))"
    }
}
