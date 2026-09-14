// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsInstrument

/// Running several mutants in one process, and sharing out the answers correctly.
///
/// A test bundle costs what it costs to load whether one test runs or forty, so a package
/// with good locality spends most of a run starting processes rather than running tests.
/// Two thousand mutants at five tests each is ten thousand test executions and two thousand
/// launches; if a launch costs what twenty tests cost, the launches are five times the bill.
extension Scheduler {

    /// Runs one batch and hands each of its mutants the answer about itself.
    ///
    /// A batch runs to the end rather than stopping at the first failure: stopping is right
    /// for one mutant, where the answer is known at that point, and wrong here, where the
    /// other mutants in the process have not been asked yet.
    ///
    /// A test that fails and belongs to nobody means the batch was built wrong. Rather than
    /// credit the kill to whoever happens to be nearby, the caller is told and the mutants
    /// are run one at a time.
    func results(
        of batch: Batch, in path: WorkspaceRelativePath, worker: Int
    ) async -> [MutantResult]? {
        let verdict = await trial(worker: worker)
            .run(
                waking: batch.mutants.map(\.index),
                onlyTests: batch.tests,
                stoppingAtFirstFailure: false
            )

        guard verdict.outcome == .killed || verdict.outcome == .survived else { return nil }
        var killers: [UInt32: [String]] = [:]
        for test in verdict.killedBy {
            guard let owner = batch.mutant(killedBy: test) else { return nil }
            killers[owner, default: []].append(test)
        }

        return batch.mutants.map { mutant in
            MutantResult(
                identity: mutant.identity,
                path: path,
                rule: mutant.rule,
                span: mutant.span,
                verdict: Verdict(
                    outcome: killers[mutant.index] == nil ? .survived : .killed,
                    killedBy: killers[mutant.index] ?? [],
                    firstFailure: killers[mutant.index] == nil ? nil : verdict.firstFailure,
                    startedTests: verdict.startedTests,
                    durationMilliseconds: verdict.durationMilliseconds,
                    termination: verdict.termination
                ),
                attempts: 1
            )
        }
    }

    /// One unit of work: a batch when the coverage allows it, a mutant when it does not.
    func answers(
        for unit: Unit, in path: WorkspaceRelativePath, worker: Int
    ) async -> [MutantResult] {
        switch unit {
        case .alone(let mutant):
            return [await result(of: mutant, in: path, worker: worker)]
        case .together(let batch):
            if let shared = await results(of: batch, in: path, worker: worker) { return shared }
            // The batch said something it could not share out. Ask them separately rather
            // than hand several mutants one answer, which is the mistake a batch exists to
            // avoid rather than to make.
            var apart: [MutantResult] = []
            for mutant in batch.mutants {
                apart.append(await result(of: mutant, in: path, worker: worker))
            }
            return apart
        }
    }

    /// What a worker is handed.
    enum Unit: Sendable {
        case alone(InstrumentedMutant)
        case together(Batch)

        var mutants: [InstrumentedMutant] {
            switch self {
            case .alone(let mutant): [mutant]
            case .together(let batch): batch.mutants
            }
        }
    }

    /// Splits the catalogue into the units a run will actually execute.
    ///
    /// Without coverage nothing can be batched, because a batch is sound only when no test
    /// reaches two of its mutants and "unknown" means "possibly every test".
    func units(for mutants: [InstrumentedMutant]) -> [Unit] {
        guard let coverage else { return mutants.map { .alone($0) } }

        let batched = Batch.group(mutants, using: coverage)
        let inBatches = Set(batched.flatMap { $0.mutants.map(\.index) })
        return mutants.filter { !inBatches.contains($0.index) }.map { Unit.alone($0) }
            + batched.map { Unit.together($0) }
    }
}
