// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsConsole
import SwiftMutantsDiscover
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsReport
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

    /// That some of a package's tests do not run in the copy a run happens in.
    ///
    /// Every run happens in a copy of the package, so a test whose fixtures live outside it
    /// - a document in the repository above, a vector file, a seed corpus - cannot run
    /// there, and a suite written to notice that declares itself disabled rather than
    /// failing. swift-testing says so on the event stream; this tool used to drop the
    /// event, which made a skipped test indistinguishable from one that ran and passed.
    ///
    /// The mutants only those tests cover then come back as survivors nobody can write a
    /// test for: the test already exists, and it cannot run here. A `--strict` gate over
    /// that list can never go green, and the answer is to pin the constant a second time
    /// inside the package rather than to write a test - which nobody arrives at while the
    /// tool is silent.
    ///
    /// Reported from a package with five such suites, pinning a Base32 alphabet, two
    /// key-derivation strings and a salt order against the documents that specify them.
    ///
    /// Said with what it costs rather than only that it happened, because a count on its
    /// own reads as trivia. What it costs is that the score is about less of the package
    /// than it looks like.
    static func skipped(_ tests: [String]) -> String? {
        guard !tests.isEmpty else { return nil }
        let named = tests.prefix(Self.skippedNamed)
        return """
            \(tests.count) of your tests stepped aside in the copy this run happens in:
            \(named.map { "  \($0)" }.joined(separator: "\n"))\
            \(tests.count > named.count ? "\n  ... and \(tests.count - named.count) more" : "")

            A test whose fixtures live outside the package - a document in the repository \
            above it, a vector file, a seed corpus - cannot run in a copy of the package \
            alone. Anything only those tests cover cannot be caught here, and will report \
            as surviving however good they are. Pinning the same constant inside the \
            package is the answer; writing another test is not.
            """
    }

    /// How many skipped tests to name before saying how many more there were.
    ///
    /// A package that disables a hundred in a copy would otherwise bury the summary under
    /// them, and the first few are enough to recognise which suites they are.
    static let skippedNamed = 5

    /// Where this run is keeping its recording.
    ///
    /// Said at the start rather than at the end, because the run somebody asked to record
    /// is the run they expect to have trouble with - and a path printed after a run that
    /// hung is a path they never see.
    static func tracing(_ file: URL) -> String {
        "recording this run to \(file.path)"
    }

    /// What the last run got to, when it did not get to the end.
    ///
    /// A report is written once, when a run finishes, so an interrupted one used to produce
    /// the same sentence as a package nobody has measured: nothing has been measured here
    /// yet. That is not true, and it is the least useful thing to say to somebody who has
    /// just lost an hour - the answers exist, they were written down as they arrived.
    ///
    /// Counts and no score. A score has a denominator: the mutants a run decided not to
    /// count, the ones it never reached, the ones somebody wrote down as expected. An
    /// interrupted run has none of that, and a percentage taken from a prefix would be a
    /// number nobody measured.
    ///
    /// Nothing at all when there is nothing, which is every package nobody has run.
    static func interrupted(_ answers: [Ledger.Answer]) -> String? {
        guard !answers.isEmpty else { return nil }
        let killed = answers.count { $0.outcome == "killed" }
        let survived = answers.count { $0.outcome == "survived" }
        return """
            the last run did not finish, and this is what it had got to. No score, because \
            a score needs a denominator and an interrupted run has none.

              \(answers.count) answered  \(killed) killed  \(survived) survived

            Run it again for a score. Nothing here is lost by doing so: an answer this run \
            already has is an answer the next one can take from its cache.
            """
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
        // program and not a gap in the measurement: a mutant that ran out of time once is
        // retried on its own and comes back `inconclusive` if it then finishes, so
        // everything here failed to finish twice. "This change makes your program stop
        // terminating" is a stronger statement than most survivors make, and it is
        // unactionable while it is a digit in a tally.
        //
        // What the retry rules out is *this run* being what the trial was waiting for.
        // It does not rule out the machine, and this line used to say "on a quiet
        // machine", which claims something nothing here measured. Reported from a machine
        // where Spotlight and Gatekeeper held half a core between them for hours and a
        // freshly built executable sat waiting to be allowed to start, having used a
        // hundredth of a second of processor time: the retry would have been as stuck as
        // the first attempt, and the sentence would have told somebody their program
        // stopped terminating.
        let stuck = outcome.results.filter { $0.verdict.outcome == .timedOut }
        if !stuck.isEmpty {
            lines +=
                [
                    "",
                    "these never finished, twice, the second time with this run to themselves:",
                ]
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
