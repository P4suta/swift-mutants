// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsEngine
import SwiftMutantsValidate

/// What each phase of a run says while it is happening.
///
/// Its own file because the stages are the one part of the narration that grows with the
/// pipeline: every phase added since the first has added a case here, and a reader looking
/// for "what does it print while it is running" should not have to pass the summary, the
/// survivor rows and the exit-code wording to find it.
extension Narration {

    /// What a run says that is news rather than a phase.
    ///
    /// A phase is a headline: one line, held in a frame of fixed height, replaced by the
    /// next phase a second later. This is the other kind of thing a run has to say - a
    /// finding about the package that the reader needs to keep, whose worth is the
    /// explanation rather than the headline, and which is several lines long because of it.
    ///
    /// A drawn run leaves the last frame where it is, says this underneath it, and starts
    /// drawing again below, which is the same thing `finish` already does for the summary.
    /// Drawing it instead would wipe it off the screen a second later.
    static func news(for stage: RunStage) -> String? {
        switch stage {
        case .skipped(let tests): Self.skipped(tests)
        default: nil
        }
    }

    /// What each phase says, or nothing for the ones that say it themselves.
    static func line(for stage: RunStage) -> String? {
        switch stage {
        case .snapshotting: "copying the package"
        case .discovering: "reading the sources"
        case .priming: "building your package as you wrote it, once"
        case .skipped(let tests): Self.skipped(tests)
        default: preparation(for: stage)
        }
    }

    /// What the phases that make a tree to run say.
    ///
    /// Split from `line(for:)` along the seam the run itself has: everything above happens
    /// to the package as the author wrote it, and everything here happens to a tree this
    /// tool built, which is the distinction a reader is making when they ask whose fault a
    /// failure at this point is.
    static func preparation(for stage: RunStage) -> String? {
        switch stage {
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
        case .halved(let compiles, let narrowing, let refused):
            // A line per compile. The halving is the one phase that can run for a long
            // time saying nothing, and from outside a bisection working and a bisection
            // that has died are the same silence. Reported by somebody whose run printed
            // `halving 802 mutants` and then nothing for forty minutes.
            //
            // The compile count rather than a percentage, because nobody can say in
            // advance how many it will take: it is one per halving and the halvings
            // multiply with the number of refusals, which is the thing being found out.
            "  compile \(compiles), narrowed to \(narrowing)"
                + (refused > 0 ? " - this one is refused" : "")
        case .halving(let mutants, let read, let unplaceable, let wrote):
            "  the compiler would not say which, so halving \(mutants) mutants"
                + Self.whyTheFastPathDidNotTake(
                    read: read, unplaceable: unplaceable, wrote: wrote)
        }
    }

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
                + "from how long your suite takes"
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
}
