// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import SwiftMutantsBuild
public import SwiftMutantsRunner

/// Which tests reach which mutants.
///
/// The difference between a run that costs `mutants × tests` and one that costs
/// `mutants × the few tests that matter`. Without it every mutant has to be offered the
/// whole suite, because any test might be the one that notices; with it a mutant is
/// offered the tests that actually execute the line it changed, and a mutant no test
/// reaches costs no process at all.
///
/// The numbers are worth writing down. Six hundred mutants against four hundred tests is a
/// quarter of a million test executions if every mutant meets every test. If each mutant is
/// reached by a handful, it is a few thousand - and the difference is not a constant
/// factor, it is `Θ(N·T)` against `Θ(N·c̄ + T)`.
public struct Coverage: Sendable {

    /// For each mutant index, the tests that reached it.
    ///
    /// Absent rather than empty for a mutant nothing reached, because the two mean
    /// different things and only one of them is a finding: no test runs this code.
    private let byMutant: [UInt32: [String]]

    /// Every test that ran during the probe, in a fixed order.
    public let tests: [String]

    /// Records what a probe found.
    ///
    /// Each mutant's tests are ordered by how much else that test reaches, fewest first.
    /// A killed mutant stops at the test that notices it, so the order decides how many of
    /// the others it walks through first - and a test that reaches almost nothing is a
    /// test written about almost nothing, which is exactly the test most likely to assert
    /// on the behaviour a mutant changed. A test that reaches half the package asserts on
    /// something further away.
    ///
    /// It costs nothing: the inverted map is already in hand, and the ordering is decided
    /// once rather than per mutant.
    public init(byMutant: [UInt32: [String]], tests: [String]) {
        var reach: [String: Int] = [:]
        for tests in byMutant.values {
            for test in tests { reach[test, default: 0] += 1 }
        }
        // Ties broken by name, so two runs of the same package order them the same way.
        self.byMutant = byMutant.mapValues { covering in
            covering.sorted { ((reach[$0] ?? 0), $0) < ((reach[$1] ?? 0), $1) }
        }
        self.tests = tests
    }

    /// The tests that reach a mutant, or nothing when none do.
    ///
    /// `nil` and `[]` would be the same set and are not the same news: one is "these tests
    /// cover it" and the other is "nothing covers it, so it cannot be killed and the
    /// report should say so rather than pretending it was measured".
    public func tests(reaching index: UInt32) -> [String]? { byMutant[index] }

    /// How many mutants nothing reaches.
    public func uncovered(among indices: [UInt32]) -> Int {
        indices.count { byMutant[$0] == nil }
    }
}

/// Finds out which tests reach which mutants, by asking each test on its own.
///
/// One process per test, which sounds expensive and is not: a process launch costs about
/// what a handful of tests cost, and running *one* test is cheap even when running all of
/// them is not. The whole phase is `Θ(tests)` and it replaces a per-mutant term of
/// `Θ(tests)` with `Θ(the tests that matter)`.
///
/// Each test is run with nothing activated, so the probe records what the *original*
/// program reaches. That is the right question: a mutant is reachable if the code it sits
/// in is reachable, and the mutated branch is never taken during a probe.
public struct Prober: Sendable {

    private let plan: TestPlan
    private let runner: Runner
    private let scratch: URL
    private let timeout: Duration?
    private let jobs: Int

    /// Prepares to probe inside `scratch`.
    public init(
        plan: TestPlan,
        runner: Runner,
        scratch: URL,
        timeout: Duration? = .seconds(120),
        jobs: Int = 4
    ) {
        self.plan = plan
        self.runner = runner
        self.scratch = scratch
        self.timeout = timeout
        self.jobs = max(1, jobs)
    }

    /// Asks each of these tests what it reaches.
    public func probe(
        _ tests: [String],
        progress: @Sendable (Int) -> Void = { _ in }
    ) async -> Coverage {
        guard !tests.isEmpty else { return Coverage(byMutant: [:], tests: []) }

        var reached: [UInt32: [String]] = [:]
        await withTaskGroup(of: (String, Set<UInt32>).self) { group in
            var next = 0
            while next < min(jobs, tests.count) {
                let test = tests[next]
                let worker = next
                group.addTask { [self] in
                    (test, await self.indices(reachedBy: test, worker: worker))
                }
                next += 1
            }
            var done = 0
            while let (test, indices) = await group.next() {
                for index in indices.sorted() { reached[index, default: []].append(test) }
                done += 1
                progress(done)
                guard next < tests.count else { continue }
                let test = tests[next]
                let worker = next % jobs
                group.addTask { [self] in
                    (test, await self.indices(reachedBy: test, worker: worker))
                }
                next += 1
            }
        }
        return Coverage(byMutant: reached, tests: tests)
    }

    private func indices(reachedBy test: String, worker: Int) async -> Set<UInt32> {
        let log = scratch.appending(path: "probe-\(worker)-\(abs(test.hashValue)).log")
        try? FileManager.default.removeItem(at: log)

        var environment = plan.environment
        environment["SWIFT_MUTANTS"] = "1"
        environment["SWIFT_MUTANTS_TEST_TOKEN"] = "\(worker)"
        environment[Self.probeVariable] = log.path

        let outcome = await runner.run(
            ProcessSpec(
                kind: .probe,
                executable: plan.executable,
                arguments: plan.arguments + [
                    "--no-parallel", "--filter", Self.exactly(test),
                ],
                directory: plan.directory,
                environment: environment,
                timeout: timeout
            )
        )
        _ = outcome
        defer { try? FileManager.default.removeItem(at: log) }
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { UInt32($0) })
    }

    /// The environment variable the generated runtime writes its findings to.
    static let probeVariable = "SWIFT_MUTANTS_PROBE"

    /// A pattern that matches one test and nothing else.
    ///
    /// swift-testing takes a regular expression, and a test's identifier is full of
    /// characters a regular expression reads as instructions - parentheses, dots, the
    /// colons of a source location. Every one of them is escaped, because a filter that
    /// matched more than it meant would attribute one test's reach to another, and a filter
    /// that matched less would report a mutant as unreachable that a test reaches every
    /// day.
    static func exactly(_ test: String) -> String {
        var pattern = "^"
        for character in test {
            if "\\^$.|?*+()[]{}/-".contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
        return pattern + "$"
    }
}
