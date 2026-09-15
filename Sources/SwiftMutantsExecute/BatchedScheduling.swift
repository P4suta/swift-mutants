// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsBuild
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
    func results(of batch: Batch, worker: Int) async -> [MutantResult]? {
        let verdict = await trial(worker: worker)
            .run(
                waking: batch.mutants.map(\.index),
                onlyTests: batch.tests,
                settling: .eachOwner(batch.owners)
            )

        guard verdict.outcome == .killed || verdict.outcome == .survived else { return nil }

        // A process that stopped part way has nothing to share out. The mutants whose
        // tests had not run yet were not measured, and "no test failed for you" is exactly
        // what surviving looks like - so sharing it out would report every one of them as
        // having survived a program that died.
        //
        // A trap is the case that matters, and it is not rare: bounds arithmetic is where
        // mutation testing earns its keep, and a mutation to bounds arithmetic traps. The
        // process dies on a signal with no failure event, because there is no assertion,
        // only a trap. Measured on a package of two hand-written binary codecs: alone the
        // mutant was killed, in company every member of its batch came back a survivor
        // whose missing assertion could not be written - the assertion it wants is "the
        // process is still alive".
        guard verdict.termination.settled else { return nil }

        var killers: [UInt32: [String]] = [:]
        for test in verdict.killedBy {
            guard let owner = batch.mutant(killedBy: test) else { return nil }
            killers[owner, default: []].append(test)
        }

        return batch.mutants.map { mutant in
            MutantResult(
                identity: mutant.identity,
                path: mutant.path,
                rule: mutant.rule,
                span: mutant.span,
                original: mutant.original,
                replacement: mutant.replacement,
                verdict: Verdict(
                    outcome: killers[mutant.index] == nil ? .survived : .killed,
                    killedBy: killers[mutant.index] ?? [],
                    firstFailure: Self.message(
                        killedBy: killers[mutant.index] ?? [], in: verdict),
                    startedTests: verdict.startedTests,
                    durationMilliseconds: verdict.durationMilliseconds,
                    termination: verdict.termination
                ),
                attempts: 1,
                index: mutant.index
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
    static func message(killedBy: [String], in verdict: Verdict) -> String? {
        guard !killedBy.isEmpty, let first = verdict.killedBy.first, killedBy.contains(first)
        else {
            return nil
        }
        return verdict.firstFailure
    }

    /// One unit of work: a batch when the coverage allows it, a mutant when it does not.
    func answers(for unit: Unit, worker: Int) async -> [MutantResult] {
        switch unit {
        case .alone(let mutant), .unreached(let mutant):
            return [await result(of: mutant, worker: worker)]
        case .together(let batch):
            if let shared = await results(of: batch, worker: worker) { return shared }
            // The batch said something it could not share out. Ask them separately rather
            // than hand several mutants one answer, which is the mistake a batch exists to
            // avoid rather than to make.
            var apart: [MutantResult] = []
            for mutant in batch.mutants {
                apart.append(await result(of: mutant, worker: worker))
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

        /// Whether answering it costs a process at all.
        var startsSomething: Bool {
            if case .unreached = self { false } else { true }
        }

        /// How many processes answering it costs.
        ///
        /// One per test bundle it spans, because a package builds one bundle per test
        /// target and a unit faces the ones its tests live in. This was "one, unless
        /// nothing reaches it" while a package built one bundle; leaving it there would
        /// have understated every count - and understated it in the flattering direction,
        /// making batching look like a larger saving than it is.
        ///
        /// A unit with no coverage faces every bundle, because any test might be the one
        /// that notices.
        func processes(using coverage: Coverage?, ofTotal bundles: Int) -> Int {
            guard startsSomething else { return 0 }
            guard let coverage else { return max(bundles, 1) }
            let tests: [String]
            switch self {
            case .alone(let mutant):
                tests = coverage.tests(reaching: mutant.index) ?? []
            case .together(let batch):
                tests = batch.tests
            case .unreached:
                return 0
            }
            let spanned = Set(tests.compactMap { TestBundles.module(of: $0) }).count
            return spanned == 0 ? max(bundles, 1) : spanned
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
