// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsExecute
import Testing

@testable import SwiftMutantsEngine

/// Survivors a project has written down as evidence rather than as gaps.
///
/// Some survivors are not holes. A mutant in code that is unreachable by construction, or
/// one whose behaviour genuinely cannot be observed, will survive every suite anybody
/// writes - and a tool whose list never shrinks below those is a tool whose list nobody
/// reads.
///
/// This is not a skip list, and the difference is the whole design. A skipped mutant is not
/// measured and nothing is learned; an expected one is measured on every run, and three
/// things are then possible. It survives, and the expectation is met. It is killed, which
/// means somebody wrote the test after all and the expectation is now a lie in their
/// configuration. Or it is no longer in the catalogue at all, which means the code moved
/// and nobody updated the note.
///
/// The last two are failures. An expectation that quietly stopped applying is worse than no
/// expectation, because somebody is relying on it.
@Suite("Expectations")
struct ExpectationTests {

    static func identity(_ name: String) -> String { Digest.of(name).hexadecimal }

    static func expectation(
        _ name: String, _ reason: String = "unreachable by construction"
    )
        -> Configuration.Expectation
    {
        Configuration.Expectation(identity: Self.identity(name), reason: reason)
    }

    static func checked(
        _ expectations: [Configuration.Expectation],
        against results: [(String, Outcome)],
        about scope: RunScope = .everything
    ) -> Expectations.Verdict {
        Expectations.check(
            expectations,
            against: Dictionary(
                uniqueKeysWithValues: results.map { (Self.identity($0.0), $0.1) }),
            about: scope
        )
    }

    @Test("is met by a survivor it named")
    func metBySurvivor() {
        let checked = Self.checked([Self.expectation("a")], against: [("a", .survived)])
        #expect(checked.met == 1)
        #expect(checked.contradicted.isEmpty)
        #expect(checked.stale.isEmpty)
    }

    /// Somebody wrote the test. The note in their configuration now says something untrue,
    /// and the only way they find out is if this says so.
    @Test("is contradicted by a mutant something caught")
    func contradictedByAKill() {
        let checked = Self.checked([Self.expectation("a")], against: [("a", .killed)])
        #expect(checked.met == 0)
        #expect(checked.contradicted.count == 1)
        #expect(checked.contradicted.first?.reason.contains("caught") == true)
    }

    /// A confirmed timeout counts as a detection everywhere else in this tool, so it has to
    /// count as one here too - otherwise a mutant that hangs the suite would satisfy an
    /// expectation that says nothing catches it.
    @Test("is contradicted by a mutant that hung the suite")
    func contradictedByATimeout() {
        let checked = Self.checked([Self.expectation("a")], against: [("a", .timedOut)])
        #expect(checked.contradicted.count == 1)
        #expect(checked.met == 0)
    }

    /// The code moved and nobody updated the note. An expectation that quietly stopped
    /// applying is worse than none, because somebody is relying on it.
    @Test("is stale when the mutant it names is gone")
    func staleWhenGone() {
        let checked = Self.checked([Self.expectation("gone")], against: [("a", .survived)])
        #expect(checked.stale.count == 1)
        #expect(checked.stale.first?.identity == Self.identity("gone"))
    }

    /// A mutant that could not be measured this time is not evidence either way, and
    /// calling it a contradiction would fail a build because a machine was busy.
    @Test(
        "says nothing about a mutant nothing was established about",
        arguments: [Outcome.inconclusive, .errored, .notRun, .rejected]
    )
    func nothingEstablished(_ outcome: Outcome) {
        let checked = Self.checked([Self.expectation("a")], against: [("a", outcome)])
        #expect(checked.met == 0)
        #expect(checked.contradicted.isEmpty)
        #expect(checked.stale.isEmpty)
    }

    /// A mutant proved equivalent was never a finding, so an expectation about it is a note
    /// somebody can now delete - which is a thing to say, not a thing to fail over.
    @Test("says an expectation about an equivalent mutant is no longer needed")
    func equivalentIsNotNeeded() {
        let checked = Self.checked([Self.expectation("a")], against: [("a", .equivalent)])
        #expect(checked.superseded.count == 1)
        #expect(checked.contradicted.isEmpty)
    }

    /// A run about four changed files never looked at the rest of the catalogue. Calling
    /// the expectations it did not measure stale would fail somebody's build for using
    /// `--changed`, and the note in their configuration would be true the whole time.
    @Test("says nothing about what a narrowed run never looked at")
    func narrowedRunSaysNothingAboutTheRest() {
        let narrowed = Self.checked(
            [Self.expectation("gone")],
            against: [("a", .survived)],
            about: .changed(since: "HEAD", files: 1)
        )
        #expect(narrowed.stale.isEmpty)
        #expect(narrowed.isSatisfied)
    }

    /// It still checks the ones it did measure. A narrowed run is narrower, not silent.
    @Test("still contradicts what a narrowed run did measure")
    func narrowedRunStillContradicts() {
        let narrowed = Self.checked(
            [Self.expectation("a")],
            against: [("a", .killed)],
            about: .changed(since: "HEAD", files: 1)
        )
        #expect(narrowed.contradicted.count == 1)
        #expect(!narrowed.isSatisfied)
    }

    @Test("holds a configuration with no expectations in it")
    func noExpectations() {
        let checked = Self.checked([], against: [("a", .survived)])
        #expect(checked.met == 0)
        #expect(checked.isSatisfied)
    }

    /// Only the two that mean somebody's configuration is wrong fail a run.
    @Test("is satisfied only when nothing in it is wrong")
    func satisfaction() {
        #expect(Self.checked([Self.expectation("a")], against: [("a", .survived)]).isSatisfied)
        #expect(!Self.checked([Self.expectation("a")], against: [("a", .killed)]).isSatisfied)
        #expect(!Self.checked([Self.expectation("gone")], against: [("a", .survived)]).isSatisfied)
        #expect(
            Self.checked([Self.expectation("a")], against: [("a", .equivalent)]).isSatisfied)
    }
}
