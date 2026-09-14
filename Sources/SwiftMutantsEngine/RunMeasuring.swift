// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsInstrument
import SwiftMutantsValidate

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
        listing: Listing,
        in pipes: URL,
        progress: @Sendable (RunStage) -> Void
    ) async -> (results: [MutantResult], remembered: Int) {
        let validated = work.validated
        let coverage = await cover(
            calibration,
            in: pipes,
            tests: calibration.baseline.startedTests,
            indices: validated.files.flatMap { $0.instrumented.mutants.map(\.index) },
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
        return measured
    }

    func measure(
        _ work: Work,
        with scheduler: Scheduler,
        remembering: Remembering,
        coverage: Coverage?,
        progress: @Sendable (RunStage) -> Void
    ) async -> (results: [MutantResult], remembered: Int) {
        let everyMutant = work.validated.files.flatMap { $0.instrumented.mutants }
        let toAsk = everyMutant.filter { remembering.answer(for: $0.index) == nil }
        if toAsk.count < everyMutant.count {
            progress(
                .remembered(known: everyMutant.count - toAsk.count, total: everyMutant.count))
        }
        progress(
            .running(total: toAsk.count, processes: scheduler.processes(for: toAsk)))

        var results: [MutantResult] = []
        var remembered = 0
        for (file, subject) in zip(work.validated.files, work.subjects) {
            guard let path = WorkspaceRelativePath(subject.name) else { continue }
            let mutants = file.instrumented.mutants.sorted { $0.index < $1.index }
            let asking = mutants.filter { remembering.answer(for: $0.index) == nil }

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
