// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCache
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsInstrument
import SwiftMutantsValidate

/// Answering a mutant from a previous run, when nothing it depends on has changed.
///
/// Separated from the pipeline that orders the steps, because this is an errand rather than
/// an argument: the argument is that a run may skip what it already knows, and it is made
/// in ``Remembering``.
extension Run {

    /// A result put together from what a previous run established.
    ///
    /// The verdict says `.stopped`, because that is what happened here: nothing was
    /// started. A termination invented to look like a process would be a report claiming a
    /// process that never existed.
    ///
    /// The tests it names are the ones the coverage offers it, which is the truth about the
    /// measurement being reported rather than about this afternoon. It also has to be
    /// there: a survivor with no tests against its name is how this tool says "nothing
    /// reaches this", and a remembered survivor would otherwise be reported as unreachable
    /// code somebody should delete.
    static func result(
        of mutant: InstrumentedMutant,
        at path: WorkspaceRelativePath,
        from answer: CachedAnswer,
        offering tests: [String]
    ) -> MutantResult {
        MutantResult(
            identity: mutant.identity,
            path: path,
            rule: mutant.rule,
            span: mutant.span,
            original: mutant.original,
            replacement: mutant.replacement,
            verdict: Verdict(
                outcome: answer.outcome,
                killedBy: answer.killedBy,
                firstFailure: answer.killedBy.first,
                startedTests: tests,
                durationMilliseconds: answer.durationMilliseconds,
                termination: .stopped
            ),
            attempts: 0
        )
    }

    /// What may be remembered about this run's mutants.
    func remembering(_ work: Work, coverage: Coverage?, listing: Listing) -> Remembering {
        guard configuration.cache.mode != .disabled else { return .nothing }
        var files: [UInt32: WorkspaceRelativePath] = [:]
        var identities: [UInt32: MutantIdentity] = [:]
        for (file, subject) in zip(work.validated.files, work.subjects) {
            guard let path = WorkspaceRelativePath(subject.name) else { continue }
            for mutant in file.instrumented.mutants {
                files[mutant.index] = path
                identities[mutant.index] = mutant.identity
            }
        }
        return Remembering.of(
            files: files,
            identities: identities,
            coverage: coverage,
            digests: listing.digests,
            cache: OutcomeCache.read(from: OutcomeCache.location(for: root))
        )
    }

    /// Writes down what this run learned, for the next one.
    ///
    /// A cache that cannot be written is a warning, not a failure: the run answered the
    /// question it was asked, and the only cost is that the next one asks again.
    func keep(
        _ results: [MutantResult], _ validated: Validation, remembering: Remembering
    ) {
        guard configuration.cache.mode != .disabled else { return }
        var index: [MutantIdentity: UInt32] = [:]
        for file in validated.files {
            for mutant in file.instrumented.mutants { index[mutant.identity] = mutant.index }
        }
        try? remembering.recording(results, by: index)
            .write(to: OutcomeCache.location(for: root))
    }
}
