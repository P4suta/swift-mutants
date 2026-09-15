// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsInstrument
import Testing

@testable import SwiftMutantsExecute

/// Offering a mutant only the tests that reach it.
///
/// The difference between a run that costs `mutants × tests` and one that costs
/// `mutants × the few tests that matter`. Six hundred mutants against four hundred tests
/// is a quarter of a million test executions if every mutant meets every test; if each is
/// reached by a handful it is a few thousand, and the difference is `Θ(N·T)` against
/// `Θ(N·c̄ + T)` rather than a constant factor.
@Suite("Coverage")
struct CoverageTests {

    static func mutants() throws -> [InstrumentedMutant] { try SchedulerTests.mutants() }

    static func scheduler(_ fake: ScriptedBundle.Fake, coverage: Coverage?) -> Scheduler {
        Scheduler(
            plan: fake.plan,
            runner: SchedulerTests.runner(),
            scratch: fake.scratch,
            timeout: .seconds(30),
            jobs: 2,
            coverage: coverage
        )
    }

    /// The tests a mutant is offered are the ones that reach it, and no others.
    @Test("runs only the tests that reach a mutant")
    func offersOnlyTheCoveringTests() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        let coverage = Coverage(
            byMutant: [mutants[0].index: ["P.S/a()", "P.S/b()"]],
        )
        _ = await Self.scheduler(fake, coverage: coverage)
            .run([mutants[0]], in: SchedulerTests.path())

        let argv = try String(contentsOf: fake.scratch.appending(path: "argv.txt"), encoding: .utf8)
        #expect(argv.contains(Prober.exactly("P.S/a()")))
        #expect(argv.contains(Prober.exactly("P.S/b()")))
        #expect(!argv.contains(Prober.exactly("P.S/c()")))
    }

    /// A mutant nothing reaches cannot be caught, and finding that out by running the
    /// suite would spend the most expensive thing this tool does on a question already
    /// answered.
    @Test("answers a mutant nothing reaches without starting anything")
    func doesNotRunUnreachedMutants() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        let coverage = Coverage(byMutant: [:])
        let results = await Self.scheduler(fake, coverage: coverage)
            .run(mutants, in: SchedulerTests.path())

        #expect(results.count == mutants.count)
        #expect(results.allSatisfy { $0.verdict.outcome == .survived })
        #expect(results.allSatisfy { $0.attempts == 0 })
        // Nothing ran, so the bundle wrote down no invocation. Empty rather than absent:
        // the fixture makes the file before anything starts, so that this says "none" and
        // not "the file is missing, which might mean none".
        let argv = try String(
            contentsOf: fake.scratch.appending(path: "argv.txt"), encoding: .utf8)
        #expect(argv.isEmpty)
    }

    /// Without coverage every mutant is offered the whole suite, because any test might
    /// be the one that notices.
    @Test("offers the whole suite when nothing is known")
    func noCoverageMeansTheWholeSuite() async throws {
        let mutants = try Self.mutants()
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }

        _ = await Self.scheduler(fake, coverage: nil)
            .run([mutants[0]], in: SchedulerTests.path())

        let argv = try String(contentsOf: fake.scratch.appending(path: "argv.txt"), encoding: .utf8)
        #expect(!argv.contains("--filter"))
    }

    /// A test identifier is full of characters a regular expression reads as instructions.
    /// A filter that matched more than it meant would credit one test's reach to another;
    /// one that matched less would call a covered mutant unreachable.
    @Test(
        "matches one test and nothing else",
        arguments: [
            "PkgTests.Suite/method()/File.swift:12:6",
            "A.B/c(d:)/E.swift:1:1",
            "Odd.Name/with-dash()/F.swift:2:2",
            "Sub.Suite/plus+()/G.swift:3:3",
        ])
    func escapesTestIdentifiers(test: String) throws {
        let pattern = Prober.exactly(test)
        let expression = try Regex(pattern)
        #expect(test.wholeMatch(of: expression) != nil, "\(pattern)")
        #expect("prefix\(test)".wholeMatch(of: expression) == nil)
        #expect("\(test)suffix".wholeMatch(of: expression) == nil)
    }

    /// Two tests whose identifiers differ only where a regular expression would not care.
    @Test("does not match a different test that looks similar")
    func doesNotOverMatch() throws {
        let expression = try Regex(Prober.exactly("A.B/c()/F.swift:1:1"))
        #expect("AxB/c()/F.swift:1:1".wholeMatch(of: expression) == nil)
        #expect("A.B/cd()/F.swift:1:1".wholeMatch(of: expression) == nil)
    }

    @Test("counts what nothing reaches")
    func countsUncovered() throws {
        let coverage = Coverage(byMutant: [1: ["P.S/a()"], 3: ["P.S/b()"]])
        #expect(coverage.uncovered(among: [0, 1, 2, 3, 4]) == 3)
    }
}

/// The order a mutant's tests are offered in.
///
/// A killed mutant stops at the test that notices it, so the order decides how many of the
/// others it walks through first. With forty tests reaching an average mutant - measured on
/// this repository - putting the likeliest first is the difference between one test and
/// twenty for most of the catalogue.
///
/// The rule is that a test reaching almost nothing is a test written about almost nothing,
/// which is the test most likely to assert on the behaviour a mutant changed. One reaching
/// half the package asserts on something further away. It costs nothing to apply: the
/// inverted map is already in hand.
@Suite("Test order")
struct TestOrderTests {

    @Test("offers the most specific test first")
    func specificFirst() {
        // `broad` reaches three mutants, `narrow` reaches one.
        let coverage = Coverage(
            byMutant: [
                1: ["broad", "narrow"],
                2: ["broad"],
                3: ["broad"],
            ],
        )
        #expect(coverage.tests(reaching: 1) == ["narrow", "broad"])
    }

    /// Two runs of the same package must order them the same way, or a report changes
    /// shape for no reason anybody can act on.
    @Test("breaks a tie the same way every time")
    func stableTies() {
        let coverage = Coverage(
            byMutant: [1: ["zeta", "alpha", "mu"]])
        #expect(coverage.tests(reaching: 1) == ["alpha", "mu", "zeta"])
    }

    @Test("leaves a mutant with one test alone")
    func singleTest() {
        let coverage = Coverage(byMutant: [1: ["only"]])
        #expect(coverage.tests(reaching: 1) == ["only"])
    }
}

/// Telling apart the two kinds of survivor.
///
/// A mutant no test reaches and a mutant the tests looked at and did not notice are both
/// `survived`, and they are not the same news. The first is usually the cheaper thing to
/// deal with - often by deleting the code rather than by writing an assertion - so a report
/// that ran them together would bury the easy half of the work.
@Suite("Unreached survivors")
struct UnreachedTests {

    /// A rule and a span that certainly exist, so a fixture cannot fail for a reason that
    /// has nothing to do with what it is about.
    static let rule: RuleIdentifier = {
        guard let rule = RuleIdentifier("lt-to-le", version: 1) else {
            fatalError("'lt-to-le' is not a well-formed rule name")
        }
        return rule
    }()

    static let span: SourceSpan = {
        guard let span = SourceSpan(start: 0, end: 1) else {
            fatalError("0..<1 is not a span")
        }
        return span
    }()

    static func result(_ outcome: Outcome, ran tests: [String]) -> MutantResult {
        MutantResult(
            identity: MutantIdentity(
                MutantIdentity.Inputs(
                    path: SchedulerTests.path(),
                    enclosingDeclaration: "f",
                    rule: Self.rule,
                    span: Self.span,
                    sourceDigest: Digest.of("x"),
                    originalBytes: Digest.of("<"),
                    replacementBytes: Digest.of("<=")
                )),
            path: SchedulerTests.path(),
            rule: Self.rule,
            span: Self.span,
            verdict: Verdict(
                outcome: outcome,
                killedBy: [],
                firstFailure: nil,
                startedTests: tests,
                durationMilliseconds: 0,
                termination: .exited(0)
            ),
            attempts: tests.isEmpty ? 0 : 1
        )
    }

    @Test("counts the survivors nothing reached")
    func countsUnreached() throws {
        let summary = try #require(
            RunSummary.of([
                Self.result(.survived, ran: []),
                Self.result(.survived, ran: []),
                Self.result(.survived, ran: ["P.S/a()"]),
                Self.result(.killed, ran: ["P.S/a()"]),
            ]))
        #expect(summary.survived == 3)
        #expect(summary.uncovered == 2)
    }

    /// A killed mutant that ran nothing would be a contradiction, and counting it as
    /// uncovered would make the count larger than the thing it is part of.
    @Test("counts only survivors as unreached")
    func onlySurvivors() throws {
        let summary = try #require(
            RunSummary.of([Self.result(.killed, ran: []), Self.result(.survived, ran: [])]))
        #expect(summary.uncovered == 1)
    }

    @Test("counts none when every survivor was looked at")
    func noneUnreached() throws {
        let summary = try #require(
            RunSummary.of([Self.result(.survived, ran: ["P.S/a()"])]))
        #expect(summary.uncovered == 0)
    }
}
