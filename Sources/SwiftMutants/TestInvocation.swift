// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsRunner

struct TestObservation: Sendable {
    var results = XUnitResults()
    var timedOut = false
    var diagnostic: String?
    var durationMilliseconds = 0

    func verdict(comparedTo baseline: XUnitResults) -> TestVerdict {
        let inventory: TestInventory
        if results.executed.isEmpty {
            inventory = .empty
        } else if results.executed == baseline.executed && results.skipped == baseline.skipped {
            inventory = .matched
        } else {
            inventory = .changed
        }
        return TestVerdict.classify(
            timedOut: timedOut,
            trustworthy: diagnostic == nil && results.errors == 0,
            inventory: inventory,
            failed: results.failures > 0
        )
    }
}

extension MeasurementSession {
    private static let abnormalLines = [
        OutputLinePattern(
            prefix: "error: Process '", containing: "exited with unexpected signal code"),
        OutputLinePattern(prefix: "error: Exited with signal"),
        OutputLinePattern(prefix: "error: Test process exited with signal"),
    ]
    private static let xctestLine = OutputLinePattern(prefix: "Test Case '-[")

    func test(
        products: [TestProduct],
        budget: Duration,
        activation: UInt32? = nil,
        verbose: Bool = true
    ) async throws -> TestObservation {
        let started = ContinuousClock.now
        let deadline = started + budget
        var observation = TestObservation()
        for product in products {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { observation.timedOut = true; break }
            let trial = try await execute(
                product, timeout: remaining, activation: activation, verbose: verbose)
            observation.results.merge(trial.results)
            if trial.timedOut || trial.diagnostic != nil {
                observation.timedOut = trial.timedOut
                observation.diagnostic = trial.diagnostic
                break
            }
        }
        let elapsed = ContinuousClock.now - started
        observation.durationMilliseconds =
            Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        return observation
    }

    private func execute(
        _ product: TestProduct,
        timeout: Duration,
        activation: UInt32?,
        verbose: Bool
    ) async throws -> TestObservation {
        let file = temporary.appending(path: "results-\(UUID().uuidString).xml")
        let arguments =
            [
                "test", "--skip-build", "--parallel", "--num-workers", "1",
                "--test-product", product.name, "--xunit-output", file.path,
            ] + (verbose ? ["--verbose"] : []) + options.filter.flatMap { ["--filter", $0] }
            + options.skip.flatMap { ["--skip", $0] }
        let result = try await command(
            arguments,
            kind: activation == nil ? .baseline : .mutant,
            timeout: timeout,
            activation: activation,
            matchingLines: Self.abnormalLines + [Self.xctestLine]
        )
        if result.timedOut {
            return TestObservation(timedOut: true, diagnostic: diagnostic(result))
        }
        guard result.startFailure == nil, result.exitCode == 0 || result.exitCode == 1,
            !Self.abnormalLines.contains(where: result.matchedLines.contains)
        else { return TestObservation(diagnostic: diagnostic(result)) }
        do {
            return TestObservation(
                results: try readResults(file: file, product: product, process: result)
            )
        } catch {
            return TestObservation(
                diagnostic:
                    "Missing or invalid test results for \(product.name): \(error)\n\(diagnostic(result))"
            )
        }
    }

    private func readResults(
        file: URL,
        product: TestProduct,
        process: ProcessOutcome
    ) throws -> XUnitResults {
        let testingFile = file.deletingLastPathComponent().appending(
            path: file.deletingPathExtension().lastPathComponent + "-swift-testing.xml"
        )
        var parsed = try XUnitResults.parse(
            Data(contentsOf: file),
            framework: "\(product.name):xctest"
        )
        let hasXCTest =
            !parsed.executed.isEmpty || !parsed.skipped.isEmpty
            || process.matchedLines.contains(Self.xctestLine)
        let truncatedTranscript =
            hasXCTest
            && (process.standardOutputWasCut || process.standardErrorWasCut)
        try XCTestTranscript.reconcile(
            &parsed,
            output: process.standardOutputText + "\n" + process.standardErrorText,
            framework: "\(product.name):xctest"
        )
        parsed.merge(
            try XUnitResults.parse(
                Data(contentsOf: testingFile),
                framework: "\(product.name):testing"
            )
        )
        guard !truncatedTranscript, parsed.errors == 0,
            (process.exitCode == 0 && parsed.failures == 0)
                || (process.exitCode == 1 && parsed.failures > 0)
        else { throw XUnitError.invalidDocument }
        return parsed
    }

    func requireBaseline(
        _ observation: TestObservation,
        matching expected: XUnitResults? = nil
    ) throws {
        guard !observation.timedOut, observation.diagnostic == nil,
            observation.results.failures == 0, observation.results.errors == 0,
            !observation.results.executed.isEmpty
        else {
            throw MutationTestingError(
                stage: .baseline,
                diagnostic: observation.diagnostic
                    ?? "The selected tests failed, timed out, or executed no tests."
            )
        }
        if let expected,
            observation.results.executed != expected.executed
                || observation.results.skipped != expected.skipped
        {
            throw MutationTestingError(
                stage: .baseline,
                diagnostic: "Inactive instrumentation changed which tests executed or were skipped."
            )
        }
    }
}
