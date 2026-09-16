// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsEngine
import Testing

@testable import SwiftMutantsCLI

/// A setting a project wrote down changes the run.
///
/// Four of these were read out of the file, validated, stored, and then consulted by
/// nothing: `strict` and `minimum_score` had a gate that never asked them, `formats` and
/// `directory` had a writer that never asked them. A project that wrote `strict = true` and
/// wired their build to the exit code got a gate that could not fail, and no way to find
/// that out short of reading the source of this tool.
///
/// Which is the whole of the point: a setting that does nothing is not a missing feature,
/// it is a *wrong answer* delivered with confidence to somebody who asked for the gate and
/// believes they have one.
@Suite("A setting a project wrote down")
struct SettingsThatActTests {

    static func settings(
        strict: Bool = false,
        minimumScore: Int = 0,
        formats: [ReportFormat] = [.json, .html],
        directory: String = "reports/mutation"
    ) -> Configuration {
        var configuration = Configuration()
        configuration.policy.strict = strict
        configuration.policy.minimumScore = minimumScore
        configuration.report.formats = formats
        configuration.report.directory = directory
        return configuration
    }

    /// The flag still wins, which is what a flag is for. It can only turn the gate on: a
    /// flag whose absence is `false` cannot mean "off", so an absent `--strict` says
    /// nothing rather than overruling the file.
    @Test("gates the run when the file asked for it, with no flag given")
    func strictFromTheFile() {
        let code = Gate.exitCode(
            survivors: 1,
            expectations: .unasked,
            strict: false,
            settings: Self.settings(strict: true).policy
        )
        #expect(code == 1)
    }

    @Test("gates the run when the flag asked for it, with nothing in the file")
    func strictFromTheFlag() {
        let code = Gate.exitCode(
            survivors: 1, expectations: .unasked, strict: true, settings: Self.settings().policy)
        #expect(code == 1)
    }

    /// And a run neither asked to gate is not gated. Survivors are an answer, not a
    /// failure: a tool that exited non-zero for answering is one people stop running.
    @Test("does not gate a run nobody asked to gate")
    func noGate() {
        let code = Gate.exitCode(
            survivors: 9, expectations: .unasked, strict: false, settings: Self.settings().policy)
        #expect(code == nil)
    }

    /// A score below the floor a project set is the same kind of news as a survivor under
    /// `--strict`: a gate they asked for, not this tool being wrong.
    @Test("gates a score below the floor the file set")
    func belowTheFloor() {
        let code = Gate.exitCode(
            survivors: 0,
            expectations: .unasked,
            strict: false,
            settings: Self.settings(minimumScore: 80).policy,
            scoring: 0.725
        )
        #expect(code == 1)
    }

    @Test("lets a score at the floor through")
    func atTheFloor() {
        let code = Gate.exitCode(
            survivors: 0,
            expectations: .unasked,
            strict: false,
            settings: Self.settings(minimumScore: 80).policy,
            scoring: 0.80
        )
        #expect(code == nil)
    }

    /// A good score against a floor it clears, which is the case that catches the units
    /// being wrong. A score is a fraction and `minimum_score = 80` is a percentage, so
    /// comparing them as they arrive gates *every* run that asked for a floor - and the
    /// two tests either side of this one, written in whichever units the implementation
    /// happened to use, agree with it while it does.
    ///
    /// This one cannot: 0.95 is above four fifths and below eighty, so it passes under one
    /// reading and fails under the other.
    @Test("lets a good score through a floor it clears")
    func wellAboveTheFloor() {
        let code = Gate.exitCode(
            survivors: 0,
            expectations: .unasked,
            strict: false,
            settings: Self.settings(minimumScore: 80).policy,
            scoring: 0.95
        )
        #expect(code == nil)
    }

    /// A floor of zero is the default and is not a gate. Every run is at or above it, so
    /// treating it as one would gate on a setting nobody wrote.
    @Test("is not a gate when no floor was set")
    func noFloor() {
        let code = Gate.exitCode(
            survivors: 0,
            expectations: .unasked,
            strict: false,
            settings: Self.settings().policy,
            scoring: 0
        )
        #expect(code == nil)
    }

    /// A score of nothing is not a score below a floor. It means the denominator was empty
    /// - nothing was measured - and exiting `1` would send somebody to write tests for a
    /// hole nobody has established exists. Two, because a gate that cannot be evaluated is
    /// a fact about the run rather than about their tests.
    @Test("says a floor could not be judged rather than judging it")
    func unmeasurable() {
        let code = Gate.exitCode(
            survivors: 0,
            expectations: .unasked,
            strict: false,
            settings: Self.settings(minimumScore: 80).policy,
            scoring: nil
        )
        #expect(code == 2)
    }

    /// Nothing measured and no floor asked for is an ordinary run of a package with no
    /// mutants in it, and says nothing.
    @Test("says nothing about a score nobody asked about")
    func unmeasuredWithoutAFloor() {
        let code = Gate.exitCode(
            survivors: 0,
            expectations: .unasked,
            strict: false,
            settings: Self.settings().policy,
            scoring: nil
        )
        #expect(code == nil)
    }

    /// An expectation that stopped applying still beats both. One thing to fix first.
    @Test("puts a stale expectation ahead of a gate")
    func staleWins() {
        let code = Gate.exitCode(
            survivors: 1,
            expectations: Expectations.Verdict(
                met: 0,
                contradicted: [],
                stale: [
                    Configuration.Expectation(
                        identity: String(repeating: "a", count: 64), reason: "moved")
                ],
                superseded: []),
            strict: true,
            settings: Self.settings(strict: true).policy,
            scoring: 0.10
        )
        #expect(code == 2)
    }
}

/// Where the documents go, and which ones.
@Suite("Where a report is written")
struct ReportSettingsTests {

    /// The flag names formats outright; an empty flag is nobody having said, so the file
    /// answers. Defaulting to the flag's own empty value would write nothing at all while
    /// reading as though the flag had won.
    @Test("writes what the file asked for when no flag named any")
    func formatsFromTheFile() {
        var configuration = Configuration()
        configuration.report.formats = [.sarif]
        #expect(RunCommand.chosen(formats: [], from: configuration.report) == [.sarif])
    }

    @Test("writes what the flag named, over the file")
    func formatsFromTheFlag() {
        var configuration = Configuration()
        configuration.report.formats = [.sarif]
        #expect(RunCommand.chosen(formats: [.json], from: configuration.report) == [.json])
    }

    /// And a project can say "none", which has to survive being read as "nothing was said".
    @Test("writes nothing when the file asked for nothing")
    func noFormats() {
        var configuration = Configuration()
        configuration.report.formats = []
        #expect(RunCommand.chosen(formats: [], from: configuration.report).isEmpty)
    }
}
