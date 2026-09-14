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
    /// It stops when every mutant in the process has been decided, which is not the same as
    /// the first failure and not the same as the last test. The first failure is wrong here
    /// because the other mutants have not been asked yet; the last test is wrong because a
    /// mutant is decided the moment one of its own tests fails or the last of them passes,
    /// and everything after that is a launch saving being spent again on tests.
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
                settling: .eachOwner(batch.owners)
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
                original: mutant.original,
                replacement: mutant.replacement,
                verdict: Verdict(
                    outcome: killers[mutant.index] == nil ? .survived : .killed,
                    killedBy: killers[mutant.index] ?? [],
                    firstFailure: Self.message(
                        of: mutant.index, killedBy: killers[mutant.index] ?? [], in: verdict),
                    startedTests: verdict.startedTests,
                    durationMilliseconds: verdict.durationMilliseconds,
                    termination: verdict.termination
                ),
                attempts: 1
            )
        }
    }

    /// The failure message that belongs to one mutant of a batch.
    ///
    /// A process that held several mutants recorded one first failure, and it is the first
    /// failure of whichever of them was caught first. Giving it to every killed member
    /// would put one mutant's words against another and send a reader to the wrong
    /// assertion - so a member gets it only when the test that produced it is one of its
    /// own, and nothing otherwise. The tests in `killedBy` are exact either way: no test
    /// reaches two mutants of a batch, by construction.
    static func message(of index: UInt32, killedBy: [String], in verdict: Verdict) -> String? {
        guard !killedBy.isEmpty, let first = verdict.killedBy.first, killedBy.contains(first)
        else {
            return nil
        }
        return verdict.firstFailure
    }

    /// One unit of work: a batch when the coverage allows it, a mutant when it does not.
    func answers(
        for unit: Unit, in path: WorkspaceRelativePath, worker: Int
    ) async -> [MutantResult] {
        switch unit {
        case .alone(let mutant), .unreached(let mutant):
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
    ///
    /// Three kinds rather than two, so that the count of processes a run will take is the
    /// count of processes it starts. A mutant nothing reaches is answered without starting
    /// anything, and calling it a unit of work would make the saving invisible in exactly
    /// the number that was supposed to show it.
    enum Unit: Sendable {
        case alone(InstrumentedMutant)
        case together(Batch)
        case unreached(InstrumentedMutant)

        var mutants: [InstrumentedMutant] {
            switch self {
            case .alone(let mutant), .unreached(let mutant): [mutant]
            case .together(let batch): batch.mutants
            }
        }

        /// Whether answering it costs a process.
        var startsSomething: Bool {
            if case .unreached = self { false } else { true }
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
        let rest = mutants.filter { !inBatches.contains($0.index) }.map { mutant in
            (coverage.tests(reaching: mutant.index)?.isEmpty ?? true)
                ? Unit.unreached(mutant) : Unit.alone(mutant)
        }
        return rest + batched.map { Unit.together($0) }
    }
}
