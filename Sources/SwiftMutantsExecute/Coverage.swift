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

    /// What each test was seen to evaluate a guard for.
    ///
    /// The same finding as ``tests(reaching:)`` read the other way round, and it answers a
    /// different question: not "who can catch this mutant" but "what does this test run".
    /// Every guard is in a file, so this is how a run knows which files a test executes -
    /// which is what an answer remembered between runs has to rest on.
    public let reach: [String: Set<UInt32>]

    /// Tests whose reach could not be established.
    ///
    /// A probe run that did not finish - it ran out of time on a loaded machine, it
    /// crashed, its log could not be read - establishes nothing about that test, and
    /// nothing is not the same as none. An empty set reads exactly like "this test reaches
    /// nothing", which is how a mutant the test catches every day comes back `survived`
    /// with no tests against its name: wrong, silent, and pointing somebody at working code
    /// to tell them to delete it.
    ///
    /// So a test nobody could establish anything about is offered to every mutant. The cost
    /// is running it more often than necessary, which is the direction to be wrong in.
    public let untrusted: [String]

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
    public init(
        byMutant: [UInt32: [String]],
        reach: [String: Set<UInt32>] = [:],
        untrusted: [String] = []
    ) {
        var breadth: [String: Int] = [:]
        for tests in byMutant.values {
            for test in tests { breadth[test, default: 0] += 1 }
        }
        // Ties broken by name, so two runs of the same package order them the same way.
        self.byMutant = byMutant.mapValues { covering in
            covering.sorted { ((breadth[$0] ?? 0), $0) < ((breadth[$1] ?? 0), $1) }
        }
        self.reach = reach
        self.untrusted = untrusted.sorted()
    }

    /// The tests that reach a mutant, or nothing when none do.
    ///
    /// `nil` and `[]` would be the same set and are not the same news: one is "these tests
    /// cover it" and the other is "nothing covers it, so it cannot be killed and the
    /// report should say so rather than pretending it was measured".
    /// Every test whose reach could not be established is in every answer, because it
    /// might reach anything.
    public func tests(reaching index: UInt32) -> [String]? {
        guard let known = byMutant[index] else {
            return untrusted.isEmpty ? nil : untrusted
        }
        return untrusted.isEmpty ? known : known + untrusted
    }

    /// Which tests reach each mutant, for a caller that needs the whole map.
    ///
    /// Named apart from ``tests(reaching:)`` because the two answer differently for a
    /// mutant nothing reaches - one says `nil` and this one simply has no entry - and a
    /// caller working out what an answer rests on needs the map rather than one lookup at
    /// a time.
    public var byMutantForCaching: [UInt32: [String]] { byMutant }

    /// How many mutants nothing reaches.
    ///
    /// None, while anything is unknown. "No test reaches this" is the claim that costs
    /// somebody an afternoon, so it is not made while a test that might have reached it
    /// went unmeasured.
    public func uncovered(among indices: [UInt32]) -> Int {
        guard untrusted.isEmpty else { return 0 }
        return indices.count { byMutant[$0] == nil }
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

    /// What runs the tests, one per worker.
    private let host: @Sendable (Int) -> any MutantHost

    /// Where the probe logs go. A worker's log is a worker's, so two of them probing at
    /// once do not read each other's findings.
    private let scratch: URL
    private let jobs: Int

    /// Prepares to probe inside `scratch`, through whatever starts the tests.
    public init(
        host: @escaping @Sendable (Int) -> any MutantHost,
        scratch: URL,
        jobs: Int = 4
    ) {
        self.host = host
        self.scratch = scratch
        self.jobs = max(1, jobs)
    }

    /// The same, for the SwiftPM path: one ``Trial`` per worker, from one built plan.
    public init(
        bundles: TestBundles,
        runner: Runner,
        scratch: URL,
        timeout: Duration? = .seconds(120),
        jobs: Int = 4
    ) {
        self.init(
            host: { worker in
                Trial(
                    bundles: bundles,
                    runner: runner,
                    scratch: scratch,
                    budget: timeout.map(Budget.flat) ?? .flat(.seconds(120)),
                    worker: worker
                )
            },
            scratch: scratch,
            jobs: jobs
        )
    }

    /// Asks each of these tests what it reaches.
    public func probe(
        _ tests: [String],
        progress: @Sendable (Int) -> Void = { _ in }
    ) async -> Probed {
        guard !tests.isEmpty else { return Probed(coverage: Coverage(byMutant: [:])) }

        var reached: [UInt32: [String]] = [:]
        var reach: [String: Set<UInt32>] = [:]
        var untrusted: [String] = []
        var cheapest: Int?
        await withTaskGroup(of: Asked.self) { group in
            var next = 0
            while next < min(jobs, tests.count) {
                let test = tests[next]
                let worker = next
                group.addTask { [self] in
                    await self.probing(test, worker: worker)
                }
                next += 1
            }
            var done = 0
            while let answer = await group.next() {
                let (test, cost) = (answer.test, answer.costMilliseconds)
                if let indices = answer.reached {
                    reach[test] = indices
                    for index in indices.sorted() { reached[index, default: []].append(test) }
                } else {
                    untrusted.append(test)
                }
                // The cheapest one, because every probe is one test in its own process and
                // the least expensive of them is the closest thing to a trial that runs
                // nothing at all. Cheapest rather than average: a probe's cost is what a
                // trial costs plus what its one test costs, and the test that cost least
                // leaves the most of what remains being the trial.
                if let cost { cheapest = min(cheapest ?? cost, cost) }
                done += 1
                progress(done)

                guard next < tests.count else { continue }
                let waiting = tests[next]
                let worker = next % jobs
                group.addTask { [self] in
                    await self.probing(waiting, worker: worker)
                }
                next += 1
            }
        }
        return Probed(
            coverage: Coverage(byMutant: reached, reach: reach, untrusted: untrusted),
            cheapestMilliseconds: cheapest
        )
    }

    /// One test's reach, and what asking cost.
    private func probing(_ test: String, worker: Int) async -> Asked {
        let (indices, cost) = await measuring(reachedBy: test, worker: worker)
        return Asked(test: test, reached: indices, costMilliseconds: cost)
    }

    /// What one test reached, or nothing when the run that should have said did not.
    ///
    /// `nil` rather than an empty set, and the difference is the whole point. A probe that
    /// ran out of time, crashed, or left no log establishes nothing about that test - and
    /// an empty set reads exactly like "this test reaches nothing", which is how a mutant
    /// the test catches every day comes back as a survivor nobody looks at.
    private func measuring(
        reachedBy test: String, worker: Int
    ) async -> (Set<UInt32>?, Int?) {
        let log = scratch.appending(path: "probe-\(worker)-\(abs(test.hashValue)).log")
        try? FileManager.default.removeItem(at: log)
        // Made empty before the run, so that the file existing means the process got to
        // the end of its job and the file being empty means the test reached nothing. The
        // runtime opens it with `O_APPEND | O_CREAT`, so an empty file it inherits is the
        // same to it as one it made. Without this the two would be the same absence, and
        // "reached nothing" is a finding while "did not finish" is a failure.
        FileManager.default.createFile(atPath: log.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: log) }

        guard let cost = await host(worker).probe(test, writingTo: log),
            let text = try? String(contentsOf: log, encoding: .utf8)
        else {
            return (nil, nil)
        }
        return (Set(text.split(separator: "\n").compactMap { UInt32($0) }), cost)
    }

    /// The environment variable the generated runtime writes its findings to.
    ///
    /// Public because every build system this tool measures has to set it, and the name is
    /// one the instrumented runtime reads: a second spelling of it anywhere would be a
    /// probe that found nothing and a run that offered every test to every mutant.
    public static let probeVariable = "SWIFT_MUTANTS_PROBE"

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

/// What a probe phase found, and what it cost to find out.
public struct Probed: Sendable {

    /// Which tests reach which mutants.
    public let coverage: Coverage

    /// The cheapest trial the probe observed, in milliseconds.
    ///
    /// Every probe is one test in its own process, so the least expensive of them is the
    /// closest thing to a measurement of what a trial costs before it runs anything -
    /// start the process, load the bundle, bring up the runtime. That is the number a
    /// per-mutant deadline needs and the one a run has always thrown away.
    ///
    /// Absent when nothing was probed, which is what a fully remembered run looks like.
    public let cheapestMilliseconds: Int?

    /// Records what the probe established.
    public init(coverage: Coverage, cheapestMilliseconds: Int? = nil) {
        self.coverage = coverage
        self.cheapestMilliseconds = cheapestMilliseconds
    }
}

/// One test, what it reached, and what asking cost.
///
/// Named rather than a tuple because it travels out of a task group, where a bare triple
/// is three positions a reader has to keep straight and a compiler will not.
struct Asked: Sendable {

    /// The test that was asked.
    let test: String

    /// What it reached, or nothing when the probe established nothing.
    let reached: Set<UInt32>?

    /// What asking cost, or nothing when the process did not finish.
    let costMilliseconds: Int?
}
