// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import ArgumentParser
import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsConsole
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsValidate
import SwiftMutantsReport
import SwiftMutantsTempOwner
import SwiftMutantsRunner
import SwiftMutantsTrace
import Synchronization

/// What `run` does around a run, as opposed to the run itself.
///
/// Claiming somewhere to work, writing the report down, saying what was found, and putting
/// it where the person who caused it is looking. Apart from the command because the command
/// is an argument about what happens in what order, and this is the errands.
extension RunCommand {

    /// A directory of this run's own, and a sweep of the ones nobody is running in.
    ///
    /// A run works inside a copy of the whole package, build directory included, so an
    /// interrupted run leaves hundreds of megabytes behind - and interrupting a mutation
    /// run is an ordinary thing to do. Sweeping is said rather than done quietly: deleting
    /// that much of somebody's disk is a thing to mention, and a reader who did not know
    /// these were piling up should find out from the tool that made them.
    func claimWorkspace() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory
        let workspace = temporary.appending(path: "swift-mutants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try? TempOwner.claim(workspace)
        let swept = TempOwner.sweep(in: temporary, besides: workspace)
        if swept > 0 { print(Narration.swept(swept)) }
        return workspace
    }

    /// Writes the run down, and says what it found.
    ///
    /// The report is kept before anything is printed, so a run whose output somebody
    /// scrolled past is still a run `explain` can answer about. Failing to keep it is a
    /// warning rather than a failure: the run answered the question it was asked.
    func publish(_ outcome: RunOutcome, at root: URL) throws {
        // Whether the copy the run happened in survives this process, which is what decides
        // whether `explain`'s command is one somebody can paste or one they would have to
        // work out has already been deleted.
        let account = RunReport(of: outcome, kept: keepTemp)
        try? ReportStore.write(account, to: ReportStore.location(for: root))
        let published = (try? Publishing.write(account, formats: Set(report), into: root)) ?? []

        if json {
            print(String(decoding: try RunReport.encoded(account), as: UTF8.self))
            return
        }
        Self.summarise(outcome, verbosity)
        // Below normal, the exit code is the answer and nothing else is said - including
        // where the documents went, because a run told to be quiet was told by a script.
        guard verbosity > .quiet else { return }
        for file in published { print(Narration.published(file, relativeTo: root)) }
        print(Narration.explainable(outcome.summary.survived))
        Self.annotate(account, in: Ambient.environment)
    }

    /// What the project wrote down, with what was typed on this invocation over the top.
    ///
    /// A flag is what somebody decided just now, so it wins over what they decided once.
    /// But only a flag that was *given*: every one of these is optional, or a flag whose
    /// absence is false, and overlaying unconditionally would put the flag's own default
    /// over whatever the file said. That reads as working - the flags do win - while
    /// quietly undoing every setting the file holds, which is the same failure as not
    /// reading the file at all, one layer further in and much harder to see.
    func asked(startingFrom file: Configuration) -> Configuration {
        var configuration = file
        if let jobs { configuration.execution.jobs = jobs }
        if let shard { configuration.execution.shard = shard }
        if let cache { configuration.cache.mode = cache }
        if let timeout { configuration.test.timeout = .seconds(timeout) }
        // A flag with no `--no-` counterpart says nothing by being absent, so it can only
        // turn equivalence proving on. A project that wants it always says so in the file.
        if tce { configuration.execution.provesEquivalence = true }
        return configuration
    }

    /// Where a run's answers are written down as they are decided.
    ///
    /// The report is written once, at the end, so a run killed a second before that is
    /// indistinguishable from a run that never started. Reported from a package of 755
    /// mutants where the harness stopped the run for memory pressure at 755 of 755 - after
    /// the last answer was in and before the summary was rendered. An hour of completed
    /// work, and the same output as never having begun.
    ///
    /// Nothing fails for being unable to keep it. The record is insurance against an
    /// interruption, and a run that refused to start without it would be a run lost to the
    /// thing that was there to prevent losing one.
    static func keepingAnswers(for root: URL) -> Ledger? {
        Ledger(at: Ledger.location(for: root))
    }

    /// How the process leaves when a run threw before it had an answer.
    ///
    /// Two, not the one a thrown error would otherwise reach the argument parser and
    /// become. A run that never got to an answer and a run whose answer was "your tests
    /// let three mutants through" want opposite things done about them, and a build system
    /// has only this number to tell them apart. Said on the way out, because the code
    /// alone leaves somebody with nothing to act on.
    static func leaving(_ error: any Error) -> ExitCode {
        let leaving = Gate.unfinished(error)
        FileHandle.standardError.write(Data((leaving.said + "\n").utf8))
        return ExitCode(leaving.code)
    }

    /// Says it again where the person who caused it is looking, if anything is.
    ///
    /// Appended to the summary rather than written over it: a workflow has other steps and
    /// each of them owns part of that page.
    static func annotate(_ report: RunReport, in environment: [String: String]) {
        guard Annotations.wanted(in: environment) else { return }
        for line in Annotations.workflowCommands(for: report) { print(line) }
        guard let file = Annotations.summaryFile(in: environment) else { return }
        let text = Annotations.stepSummary(for: report) + "\n"
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? Data(text.utf8).write(to: file)
            return
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
    }

    static func summarise(_ outcome: RunOutcome, _ verbosity: Verbosity) {
        for line in Narration.summary(of: outcome, verbosity: verbosity) { print(line) }
    }
}
