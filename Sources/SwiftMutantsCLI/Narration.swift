// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsConsole
import SwiftMutantsDiscover
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
            // "files with mutants in them", not "files": `list` counts the files it read
            // and this counts the ones that got instrumentation, which is smaller. Two
            // bare counts of "files" in two phases read as the same quantity disagreeing,
            // and a reader concludes that files went missing between them.
            "instrumenting \(mutants) mutants across \(files) files with mutants in them"
        case .proving: "proving every mutant is in the tree"
        case .building: "building the tests, once"
        case .baseline: "running the tests with nothing awake"
        case .attributing: "they failed; building your package as you wrote it to see whose fault"
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
                        + ($0.isUnaffordable ? "\n" + Self.unaffordable : "")
                } ?? "")
        }
    }

    /// What to say when the compiler ran out of budget rather than refusing anything.
    ///
    /// Different news from a refusal, and the only one of the two a reader can act on. The
    /// expression type-checks fine as written and tips over once guards wrap its
    /// subexpressions, which means it was already close to the edge - so this is a finding
    /// about their code that happens to have been made by a mutation tool.
    ///
    /// Said plainly because it otherwise reads exactly like a mutant that was not valid
    /// Swift, and a reader would take it as this tool's problem rather than theirs.
    static let unaffordable = """
          that is not a mutant it refused: the expression type-checks as you wrote it and \
        becomes too expensive once a guard is inside it. Breaking it into statements \
        usually helps, and is usually worth doing anyway.
        """

    /// The lines that carry a number somebody will want to reason about.
    static func measurement(for stage: RunStage) -> String? {
        switch stage {
        case .calibrated(let budget):
            // The widest case, and it says so. A mutant nothing narrows faces the whole
            // suite and gets this; one the probe narrowed to a handful of tests gets far
            // less, worked out per trial from what it actually faces. Printing the widest
            // figure as "each mutant" was true while there was one number and became a
            // considerable overstatement when there stopped being one.
            "  at most \(budget.seconds) seconds for a mutant nothing narrows, "
                + "from how long that took"
        case .probing(let tests): "asking each of \(tests) tests what it reaches"
        case .covered(let uncovered, let average):
            "  nothing reaches \(uncovered) of them; the rest face \(oneDecimal(average)) "
                + "tests each, not the whole suite"
        default: proportions(for: stage)
        }
    }

    /// The lines that say how much of something there was.
    static func proportions(for stage: RunStage) -> String? {
        switch stage {
        case .provingEquivalence(let survivors):
            "asking the compiler whether any of \(survivors) survivors could ever be caught"
        case .proved(let equivalent, let duplicates):
            "  \(equivalent) compile to the original and can never be caught; "
                + "\(duplicates) are another mutant again"
        case .sharded(let shard, let mine, let total):
            "this is share \(shard) of the catalogue: \(mine) of \(total) mutants"
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
        case .running(let total, let processes): running(total, in: processes)
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
    /// Nothing at all under ``Verbosity/quiet``, which is what "errors only" means. At
    /// every other level the block is the same block: somebody reads a CI log and a
    /// colleague reads their terminal, and the two have to be talking about the same thing,
    /// so there is one function that formats it and the level decides only whether it is
    /// printed.
    static func summary(of outcome: RunOutcome, verbosity: Verbosity = .normal) -> [String] {
        guard verbosity > .quiet else { return [] }
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
        // Named rather than counted, because a confirmed deadline is a finding about the
        // program and not a gap in the measurement. The scheduler has already ruled out
        // the busy machine: a mutant that ran out of time once is retried alone and comes
        // back `inconclusive` if it then finishes, so everything here failed to finish
        // twice, the second time with the machine to itself. "This change makes your
        // program stop terminating" is a stronger statement than most survivors make, and
        // it is unactionable while it is a digit in a tally.
        let stuck = outcome.results.filter { $0.verdict.outcome == .timedOut }
        if !stuck.isEmpty {
            lines +=
                ["", "these never finished, twice, the second time on a quiet machine:"]
                + stuck.map { "  \(describe($0, at: outcome.positions[$0.path]))" }
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
        return lines + expectations(outcome.expectations) + unanchored(outcome.unanchored)
    }

    /// What a project's `[[mutation.expect]]` rows amounted to.
    ///
    /// Three different sentences, because they are three different pieces of news and only
    /// two of them are somebody's to fix. A single count - "3 expectations" - would hide
    /// the two that mean the configuration has become untrue, and those are the whole
    /// reason an expectation is not a skip list.
    ///
    /// Nothing at all when nothing was expected: a tool that printed "0 expectations" on
    /// every run would be teaching people to skip the line that matters on the run where
    /// it is not zero.
    static func expectations(_ verdict: Expectations.Verdict) -> [String] {
        guard !verdict.isEmpty else { return [] }
        var lines: [String] = [""]
        if verdict.met > 0 {
            let noun = verdict.met == 1 ? "expected survivor" : "expected survivors"
            lines.append("\(verdict.met) \(noun) did survive, as written down")
        }
        if !verdict.contradicted.isEmpty {
            lines += ["these were expected to survive, and did not:"]
            lines += verdict.contradicted.map {
                "  \(short($0.expectation.identity))  \($0.reason)"
            }
        }
        if !verdict.stale.isEmpty {
            lines += ["these are expected, and are no longer in the catalogue:"]
            lines += verdict.stale.map {
                "  \(short($0.identity))  \"\($0.reason)\" - the code moved, or the rule did"
            }
        }
        if !verdict.superseded.isEmpty {
            lines += ["these were proved equivalent, so the expectation can go:"]
            lines += verdict.superseded.map { "  \(short($0.identity))  \"\($0.reason)\"" }
        }
        return lines
    }

    /// As much of an identity as a person types, and no more.
    ///
    /// The configuration holds all sixty-four characters, because that is what a stable
    /// name is. A line somebody reads holds the twenty they would type.
    private static func short(_ identity: String) -> String {
        String(identity.prefix(Digest.shortFormLength))
    }

    /// The project's own mutants that had nothing to anchor to.
    ///
    /// Named by what each row says rather than by where it was, because where it was is
    /// exactly what is no longer true. Reported by somebody who hit ten of these in one
    /// session of refactoring: being told which row, in their own words, is what made each
    /// a two-minute fix rather than a hunt.
    ///
    /// The count, because the two failures want opposite fixes - none means the code moved
    /// and the row needs re-anchoring, more than one means the anchor is too short and
    /// wants lengthening.
    static func unanchored(_ rows: [UnanchoredMutant]) -> [String] {
        guard !rows.isEmpty else { return [] }
        return [
            "",
            "these of your own mutants had nothing to anchor to, so nothing measured them:",
        ]
            + rows.map { stale in
                let trouble =
                    stale.occurrences == 0
                    ? "not there any more"
                    : "there \(stale.occurrences) times, so the anchor is too short"
                return "  \"\(stale.row.reason)\"\n    \(stale.row.find)  -  \(trouble)"
            }
    }

    /// Where a document a run was asked for went.
    ///
    /// Relative to the package, because that is how somebody will refer to it afterwards -
    /// in a commit, in a CI step, in a sentence to a colleague.
    static func published(_ file: URL, relativeTo root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return "wrote \(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)"
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

    /// What was forgotten about a package.
    static func forgotten(_ count: Int) -> String {
        count == 0
            ? "nothing was being kept about this package."
            : "forgot \(count) of the things being kept about this package."
    }

    /// Where everything known about a failure was written down.
    ///
    /// Said, because a bundle nobody was told about is a bundle nobody has - and the moment
    /// somebody needs it is the moment the run that could have made it is over.
    static func diagnosed(_ directory: URL) -> String {
        "what this run did is written down at \(directory.path)"
    }

    /// What was cleared up before this run started, and what it means.
    ///
    /// Said rather than done quietly: deleting hundreds of megabytes of somebody's disk is
    /// a thing to mention, and a reader who did not know these were piling up should find
    /// out from the tool that made them.
    ///
    /// And phrased as evidence rather than as housekeeping, because that is what it is. A
    /// copy is removed at the end of every run that reaches one, so a copy left behind is
    /// a run of this tool that did not - killed, out of memory, a machine restarted. That
    /// matters most in the case nobody can see from inside: a process that is killed prints
    /// nothing, writes no diagnostics bundle, and leaves a log that stops mid-sentence.
    /// Reported three times in one day by somebody who each time had to work out from a
    /// truncated log that a run had died rather than finished. This is the only trace such
    /// a run leaves, and it read like tidiness.
    static func swept(_ count: Int) -> String {
        count == 1
            ? "a previous run did not finish; clearing up the copy it left behind"
            : "\(count) previous runs did not finish; clearing up the copies they left behind"
    }

    /// Where the copy a run happened in was left.
    ///
    /// Printed rather than merely not deleted: a path nobody was told about is the same as
    /// no path, and the person reading has a failure in front of them and nowhere to look.
    static func kept(_ workspace: URL) -> String {
        "the copy is kept at \(workspace.path)"
    }

    /// What a run says as the mutants start.
    ///
    /// Nothing at all when there are none to run: "running 0 mutants" is a sentence about
    /// work that is not happening, printed directly under the line that already explained
    /// why there is none.
    static func running(_ total: Int, in processes: Int) -> String? {
        guard total > 0 else { return nil }
        return total == processes
            ? "running \(total) mutants"
            : "running \(total) mutants in \(processes) processes"
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

extension Duration {
    /// Whole seconds, for a line somebody reads rather than a number anything computes.
    var seconds: Int { Int(components.seconds) }
}
