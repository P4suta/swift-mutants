// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsInstrument
import SwiftMutantsTCE
import SwiftMutantsValidate

/// Where every mutant of a run is, and what it is called.
///
/// Gathered once, because three different steps need the same two lookups - which file a
/// mutant is in, and which identity it has - and each of them walking the validated files
/// again would be three chances to walk them differently.
struct MutantCatalogue: Sendable {

    /// Which file each mutant is in.
    let files: [UInt32: WorkspaceRelativePath]

    /// What each mutant is called.
    let identities: [UInt32: MutantIdentity]

    /// Records a run's mutants directly, for a caller that has them already.
    init(files: [UInt32: WorkspaceRelativePath], identities: [UInt32: MutantIdentity]) {
        self.files = files
        self.identities = identities
    }

    /// Reads a run's mutants.
    init(_ work: Work) {
        var files: [UInt32: WorkspaceRelativePath] = [:]
        var identities: [UInt32: MutantIdentity] = [:]
        for (file, subject) in zip(work.validated.files, work.subjects) {
            guard let path = WorkspaceRelativePath(subject.name) else { continue }
            for mutant in file.instrumented.mutants {
                files[mutant.index] = path
                identities[mutant.index] = mutant.identity
            }
        }
        self.files = files
        self.identities = identities
    }
}

/// Where a run is working, and what it was given to work with.
///
/// Four things that always travel together and are never chosen separately: the copy, the
/// pipes it watches its tests through, the plan SwiftPM made for that copy, and the
/// environment every child of it gets. A step that took them one at a time would be a step
/// that could be handed the pipes of one run and the tree of another.
struct Site: Sendable {

    /// The copy the run happens in.
    let tree: URL

    /// Where the named pipes it watches its tests through are made.
    let pipes: URL

    /// The plan SwiftPM made for that copy, if it could be read.
    let plan: BuildManifest?

    /// What every child of this run is given.
    let environment: [String: String]
}

/// What a run knows about the package before it measures anything.
///
/// Two maps that always travel together: where every mutant is and what it is called, and
/// what every file in the package digests to. Coverage, the probe memory and the outcome
/// cache all need both, and each of them asking for them separately is each of them a
/// chance to be given a pair that does not match.
struct Known: Sendable {

    /// Where every mutant of this run is, and what it is called.
    let catalogue: MutantCatalogue

    /// What the package held when it was read.
    let listing: Listing
}

/// The files a run measures, each with the name the user knows it by.
///
/// The two lists are the same length and are always read together - the instrumented file
/// holds the mutants and the subject holds the path a report has to print - so they travel
/// as one thing rather than as two that a caller could pass in the wrong order.
struct Work: Sendable {

    /// What the compiler accepted, file by file.
    let validated: Validation

    /// The same files, under the names the workspace knows them by.
    let subjects: [FileUnderValidation]
}

/// Running every mutant that still has to be run.
extension Run {

    /// Whether this machine is the one that measures a mutant.
    ///
    /// Everything when no share was asked for. Otherwise decided from the mutant's own
    /// identity, so every machine works out the same partition without any of them talking
    /// to the others - and so that adding a mutant to one file does not move every mutant
    /// after it to a different machine.
    func holds(_ mutant: InstrumentedMutant) -> Bool {
        configuration.execution.shard?.holds(mutant.identity.digest) ?? true
    }

    /// A mutant another machine is measuring.
    ///
    /// Reported rather than dropped, so the columns still add up to the catalogue and a
    /// reader can see that this run was one share of it.
    static func notRun(
        _ mutant: InstrumentedMutant, at path: WorkspaceRelativePath
    ) -> MutantResult {
        MutantResult(
            identity: mutant.identity,
            path: path,
            rule: mutant.rule,
            span: mutant.span,
            original: mutant.original,
            replacement: mutant.replacement,
            verdict: Verdict(
                outcome: .notRun,
                killedBy: [],
                firstFailure: nil,
                startedTests: [],
                durationMilliseconds: 0,
                termination: .stopped
            ),
            attempts: 0
        )
    }

    /// Where the named pipes a run watches its tests through are made.
    ///
    /// A pipe is what lets a mutant be answered at the first failure rather than at the
    /// last test, so a directory that cannot be made is worth saying plainly rather than
    /// discovering one trial at a time.
    func pipesDirectory() throws(RunError) -> URL {
        let pipes = workspace.appending(path: "pipes")
        guard
            (try? FileManager.default.createDirectory(
                at: pipes, withIntermediateDirectories: true)) != nil
        else {
            throw RunError("\(pipes.path) could not be made, so the tests cannot be watched")
        }
        return pipes
    }

    /// Asks about every mutant: what the probe found, what was already known, what is left.
    func ask(
        _ work: Work,
        _ calibration: Calibration,
        at site: Site,
        listing: Listing,
        progress: @Sendable (RunStage) -> Void
    ) async -> (results: [MutantResult], remembered: Int) {
        let validated = work.validated
        let catalogue = MutantCatalogue(work)
        let coverage = await cover(
            calibration,
            probing: calibration.baseline.startedTests,
            in: site.pipes,
            against: Known(catalogue: catalogue, listing: listing),
            progress: progress
        )
        let known = remembering(work, coverage: coverage, listing: listing)
        let measured = await measure(
            work,
            with: calibration.scheduler.offering(coverage),
            remembering: known,
            coverage: coverage,
            progress: progress
        )
        keep(measured.results, validated, remembering: known)

        guard
            let proved = await equivalence(
                among: measured.results, work, at: site, progress: progress)
        else {
            return measured
        }
        progress(
            .proved(equivalent: proved.equivalent.count, duplicates: proved.duplicates.count))
        return (Self.applying(proved, to: measured.results, work), measured.remembered)
    }

    /// The results again, with what the compiler proved written into them.
    ///
    /// A mutant the compiler turned into the original is `equivalent` rather than
    /// `survived`, which takes it out of the score's denominator: it is not a hole in
    /// anybody's tests and counting it as one makes every score a little wrong and one
    /// person's afternoon a lot wrong.
    ///
    /// A duplicate stays a survivor. It is a real finding written twice, and the report
    /// says which one it is the same as rather than hiding it - hiding a finding because
    /// another one is like it is how a tool loses the one somebody would have acted on.
    static func applying(
        _ proved: Equivalence, to results: [MutantResult], _ work: Work
    ) -> [MutantResult] {
        var indices: [MutantIdentity: UInt32] = [:]
        for file in work.validated.files {
            for mutant in file.instrumented.mutants { indices[mutant.identity] = mutant.index }
        }
        return results.map { result in
            guard let index = indices[result.identity], proved.equivalent.contains(index) else {
                return result
            }
            return MutantResult(
                identity: result.identity,
                path: result.path,
                rule: result.rule,
                span: result.span,
                original: result.original,
                replacement: result.replacement,
                verdict: Verdict(
                    outcome: .equivalent,
                    killedBy: [],
                    firstFailure: nil,
                    startedTests: result.verdict.startedTests,
                    durationMilliseconds: result.verdict.durationMilliseconds,
                    termination: result.verdict.termination
                ),
                attempts: result.attempts
            )
        }
    }

    func measure(
        _ work: Work,
        with scheduler: Scheduler,
        remembering: Remembering,
        coverage: Coverage?,
        progress: @Sendable (RunStage) -> Void
    ) async -> (results: [MutantResult], remembered: Int) {
        let everyMutant = work.validated.files.flatMap { $0.instrumented.mutants }
        let mine = everyMutant.filter { self.holds($0) }
        if let shard = configuration.execution.shard {
            progress(.sharded(shard, mine: mine.count, total: everyMutant.count))
        }
        let toAsk = mine.filter { remembering.answer(for: $0.index) == nil }
        if toAsk.count < mine.count {
            progress(.remembered(known: mine.count - toAsk.count, total: mine.count))
        }
        progress(
            .running(total: toAsk.count, processes: scheduler.processes(for: toAsk)))

        var results: [MutantResult] = []
        var remembered = 0
        for (file, subject) in zip(work.validated.files, work.subjects) {
            guard let path = WorkspaceRelativePath(subject.name) else { continue }
            let mutants = file.instrumented.mutants.sorted { $0.index < $1.index }
            let asking = mutants.filter {
                self.holds($0) && remembering.answer(for: $0.index) == nil
            }

            var answered = Dictionary(
                uniqueKeysWithValues: await scheduler.run(asking, in: path) {
                    progress(.finished($0))
                }.map { ($0.identity, $0) })

            // Back into catalogue order, with the remembered answers in their places. A
            // report whose rows moved because a cache was warm would be a different report
            // about the same run.
            for mutant in mutants {
                if let fresh = answered.removeValue(forKey: mutant.identity) {
                    results.append(fresh)
                    continue
                }
                guard self.holds(mutant) else {
                    // Another machine's. Counted so the columns add up to the catalogue,
                    // and reported as what it is: not measured here.
                    results.append(Self.notRun(mutant, at: path))
                    continue
                }
                guard let answer = remembering.answer(for: mutant.index) else { continue }
                let result = Self.result(
                    of: mutant,
                    at: path,
                    from: answer,
                    offering: coverage?.tests(reaching: mutant.index) ?? []
                )
                remembered += 1
                results.append(result)
                progress(.finished(result))
            }
        }
        return (results, remembered)
    }
}
