// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import SwiftMutantsRunner
import SwiftMutantsSnapshot

extension MeasurementSession {
    func measure(instrumenting: Bool = true) async throws -> MutationReport {
        let plan = try MeasurementPlan(sources: await discover(), requested: Set(options.mutantIDs))
        let original = try await prime(originals: plan.originals)
        let suite = try await prepareSuite(plan, original: original, instrumenting: instrumenting)
        let maximum = try await repeatedBaselines(suite, original: original)
        let context = MeasurementContext(
            originals: plan.originals,
            baseline: original.observation.results,
            compileBudget: original.compileBudget,
            testBudget: options.timeout ?? max(.seconds(30), .milliseconds(maximum) * 5),
            suite: suite,
            state: original.state,
            verbose: original.observation.results.hasXCTest
        )
        let selected = Array(plan.selected.enumerated())
        let order =
            selected.filter { suite.indices[$0.element.id] != nil }
            + selected.filter { suite.indices[$0.element.id] == nil }
        var results: [(position: Int, result: MutationResult)] = []
        for (position, mutation) in order {
            try Task.checkCancellation()
            progress(.stage(.measurement))
            progress(
                .measuring(mutation: mutation, completed: results.count, total: plan.selected.count)
            )
            let result = try await measure(mutation, context: context)
            results.append((position, result))
            progress(.measured(result))
        }
        let report = MutationReport(
            results: results.sorted { $0.position < $1.position }.map(\.result))
        progress(.finished(report))
        return report
    }

    private func prime(originals: [String: String]) async throws -> OriginalBaseline {
        let built = try await build(.original, timeout: CompileDeadline.unmeasured)
        try requireSuccess(built, stage: .build)
        let products = try await products()
        let state: Snapshot
        do { state = try snapshot.recordingCurrentFiles() } catch {
            throw MutationTestingError(
                stage: .build,
                diagnostic: "Couldn't record the built package files: \(error)"
            )
        }
        progress(.stage(.baseline))
        let baseline = try await test(products: products, budget: options.timeout ?? .seconds(300))
        try requireBaseline(baseline)
        try verifySnapshot(expectedSources: originals, state: state, stage: .baseline)
        progress(.baseline(completed: 1, total: 4))
        return OriginalBaseline(
            products: products,
            observation: baseline,
            compileBudget: CompileDeadline.after(.milliseconds(built.durationMilliseconds)),
            state: state
        )
    }

    private func prepareSuite(
        _ plan: MeasurementPlan,
        original: OriginalBaseline,
        instrumenting: Bool
    ) async throws -> PreparedSuite {
        if instrumenting, !plan.selected.isEmpty,
            let suite = try await instrumentedSuite(plan, timeout: original.compileBudget)
        {
            return suite
        }
        try write(plan.originals)
        var products = original.products
        if instrumenting, !plan.selected.isEmpty {
            let restored = try await build(.original, timeout: original.compileBudget)
            try requireSuccess(restored, stage: .build)
            products = try await self.products()
        }
        return PreparedSuite(products: products, sources: plan.originals, indices: [:])
    }

    private func instrumentedSuite(
        _ plan: MeasurementPlan,
        timeout: Duration
    ) async throws -> PreparedSuite? {
        let selected = Set(plan.selected.map(\.id))
        if let suite = try await probe(plan, selected: selected, timeout: timeout) { return suite }
        var accepted: Set<String> = []
        let middle = plan.selected.count / 2
        if middle > 0 {
            try await retain(
                plan.selected[..<middle], plan: plan, accepted: &accepted, timeout: timeout)
            try await retain(
                plan.selected[middle...], plan: plan, accepted: &accepted, timeout: timeout)
        }
        guard !accepted.isEmpty else { return nil }
        guard let suite = try await probe(plan, selected: accepted, timeout: timeout) else {
            throw MutationTestingError(
                stage: .instrumentation,
                diagnostic: "Previously compilable instrumentation couldn't be rebuilt."
            )
        }
        return suite
    }

    private func retain(
        _ candidates: ArraySlice<Mutation>,
        plan: MeasurementPlan,
        accepted: inout Set<String>,
        timeout: Duration
    ) async throws {
        try Task.checkCancellation()
        let selected = accepted.union(candidates.map(\.id))
        if let suite = try await probe(plan, selected: selected, timeout: timeout) {
            accepted = Set(suite.indices.keys)
        } else if candidates.count > 1 {
            let middle = candidates.index(candidates.startIndex, offsetBy: candidates.count / 2)
            try await retain(
                candidates[..<middle], plan: plan, accepted: &accepted, timeout: timeout)
            try await retain(
                candidates[middle...], plan: plan, accepted: &accepted, timeout: timeout)
        }
    }

    private func probe(
        _ plan: MeasurementPlan,
        selected: Set<String>,
        timeout: Duration
    ) async throws -> PreparedSuite? {
        let prepared = try prepare(plan.sources, selected: selected)
        guard !prepared.indices.isEmpty, prepared.indices.count == selected.count else {
            return nil
        }
        let built = try await build(.instrumented, timeout: timeout)
        if built.startFailure != nil || built.timedOut || built.exitCode > 1 || built.exitCode < 0 {
            try requireSuccess(built, stage: .instrumentation)
        }
        guard built.exitCode == 0 else { return nil }
        let products = try await products()
        let builtSymbols = try await symbols(in: products, matching: prepared.tokens)
        guard ActivationProof.missingTokens(prepared.tokens, inSymbols: builtSymbols).isEmpty else {
            return nil
        }
        return PreparedSuite(
            products: products,
            sources: prepared.sources,
            indices: prepared.indices
        )
    }

    private func repeatedBaselines(
        _ suite: PreparedSuite,
        original: OriginalBaseline
    ) async throws -> Int {
        var maximum = original.observation.durationMilliseconds
        for repeatIndex in 1...3 {
            progress(.stage(.baseline))
            let inactive = try await test(
                products: suite.products,
                budget: options.timeout ?? .seconds(300),
                verbose: original.observation.results.hasXCTest
            )
            try requireBaseline(inactive, matching: original.observation.results)
            try verifySnapshot(
                expectedSources: suite.sources,
                state: original.state,
                stage: .baseline
            )
            maximum = max(maximum, inactive.durationMilliseconds)
            progress(.baseline(completed: repeatIndex + 1, total: 4))
        }
        return maximum
    }

    private func measure(
        _ mutation: Mutation,
        context: MeasurementContext
    ) async throws -> MutationResult {
        if let index = context.suite.indices[mutation.id] {
            let observation = try await test(
                products: context.suite.products,
                budget: context.testBudget,
                activation: index,
                verbose: context.verbose
            )
            try verifySnapshot(expectedSources: context.suite.sources, state: context.state)
            return result(mutation, observation: observation, baseline: context.baseline)
        }
        return try await measureIndividually(mutation, context: context)
    }

    private func measureIndividually(
        _ mutation: Mutation,
        context: MeasurementContext
    ) async throws -> MutationResult {
        try write(context.originals)
        guard let original = context.originals[mutation.path] else {
            throw MutationTestingError(
                stage: .measurement,
                diagnostic: "Missing source for \(mutation.id)"
            )
        }
        let edited = try mutation.applying(to: original)
        var expected = context.originals
        expected[mutation.path] = edited
        try write([mutation.path: edited])
        let compiled = try await build(
            .individual(mutantID: mutation.id),
            timeout: context.compileBudget
        )
        if compiled.exitCode != 0 || compiled.startFailure != nil || compiled.timedOut {
            let rejected =
                compiled.exitCode == 1 && compiled.startFailure == nil && !compiled.timedOut
                && (compiled.standardErrorText.contains("error:")
                    || compiled.standardOutputText.contains("error:"))
            return MutationResult(
                mutation: mutation,
                outcome: rejected ? .rejected : .errored,
                durationMilliseconds: compiled.durationMilliseconds,
                diagnostic: diagnostic(compiled)
            )
        }
        let observation = try await test(
            products: products(), budget: context.testBudget, verbose: context.verbose)
        try verifySnapshot(expectedSources: expected, state: context.state)
        return result(mutation, observation: observation, baseline: context.baseline)
    }

    private func result(
        _ mutation: Mutation,
        observation: TestObservation,
        baseline: XUnitResults
    ) -> MutationResult {
        let verdict = observation.verdict(comparedTo: baseline)
        return MutationResult(
            mutation: mutation,
            outcome: verdict.outcome,
            durationMilliseconds: observation.durationMilliseconds,
            diagnostic: observation.diagnostic ?? verdict.diagnostic
        )
    }

    private func prepare(
        _ sources: [MutationSource],
        selected: Set<String>
    ) throws -> Instrumentation {
        progress(.stage(.instrumentation))
        var prepared = Instrumentation()
        var next: UInt32 = 0
        for file in sources {
            let wanted = Set(
                zip(file.discovery.candidates, file.mutations).compactMap { candidate, mutation in
                    selected.contains(mutation.id) ? candidate : nil
                }
            )
            do {
                let rendered = try Instrument.file(
                    file.source,
                    discovery: file.discovery.keeping(wanted.contains),
                    startingAt: next
                )
                guard ActivationProof.inSource(rendered).absences.isEmpty else {
                    throw MutationTestingError(
                        stage: .instrumentation,
                        diagnostic: "Mutation markers are missing from \(file.path)"
                    )
                }
                prepared.sources[file.path] = rendered.source
                prepared.tokens.append(rendered.runtimeToken)
                for mutant in rendered.mutants {
                    prepared.indices[mutant.identity.rendered] = mutant.index
                }
                next = rendered.nextIndex
            } catch is InstrumentError {
                prepared.sources[file.path] = file.source
            }
        }
        try write(prepared.sources)
        return prepared
    }

    private func write(_ files: [String: String]) throws {
        for (path, source) in files {
            do {
                try source.write(
                    to: snapshot.root.appending(path: path),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                throw MutationTestingError(
                    stage: .instrumentation,
                    diagnostic: "Couldn't write \(path): \(error)"
                )
            }
        }
    }
}

private struct MeasurementPlan {
    let sources: [MutationSource]
    let selected: [Mutation]
    let originals: [String: String]

    init(sources: [MutationSource], requested: Set<String>) throws {
        self.sources = sources
        let all = sources.flatMap(\.mutations)
        let unknown = requested.subtracting(all.map(\.id))
        guard unknown.isEmpty else {
            throw MutationTestingError(
                stage: .input,
                diagnostic: "Unknown mutation IDs: \(unknown.sorted().joined(separator: ", "))"
            )
        }
        selected = all.filter { requested.isEmpty || requested.contains($0.id) }
        originals = Dictionary(uniqueKeysWithValues: sources.map { ($0.path, $0.source) })
    }
}

private struct OriginalBaseline {
    let products: [TestProduct]
    let observation: TestObservation
    let compileBudget: Duration
    let state: Snapshot
}

private struct PreparedSuite {
    let products: [TestProduct]
    let sources: [String: String]
    let indices: [String: UInt32]
}

private struct MeasurementContext {
    let originals: [String: String]
    let baseline: XUnitResults
    let compileBudget: Duration
    let testBudget: Duration
    let suite: PreparedSuite
    let state: Snapshot
    let verbose: Bool
}

private struct Instrumentation {
    var sources: [String: String] = [:]
    var indices: [String: UInt32] = [:]
    var tokens: [String] = []
}
