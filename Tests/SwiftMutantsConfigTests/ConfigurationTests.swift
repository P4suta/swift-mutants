// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsConfig

/// What `.swift-mutants.toml` means.
///
/// Strict in both directions. A key this tool does not know is refused with the line it was
/// written on, because the commonest mistake a configuration contains is a key nobody meant
/// to write, and a decoder that ignores one lets a project believe a setting is in effect
/// for months. A value of the wrong shape is refused the same way.
@Suite("Configuration")
struct ConfigurationTests {

    static func decode(_ text: String) throws -> Configuration {
        try Configuration(TOMLParser.parse(text))
    }

    @Test("is entirely defaults when there is nothing to read")
    func defaults() throws {
        let configuration = try Self.decode("")
        #expect(configuration.mutation.profile == .balanced)
        #expect(configuration.mutation.include.isEmpty)
        #expect(configuration.mutation.exclude.isEmpty)
        #expect(configuration.mutation.extreme == false)
        #expect(configuration.test.baselineRuns == 3)
        #expect(configuration.execution.jobs == nil)
        #expect(configuration.cache.mode == .auto)
        #expect(configuration.policy.strict == false)
        #expect(configuration.report.directory == "reports/mutation")
    }

    @Test("reads what a project wrote")
    func readsAFullConfiguration() throws {
        let configuration = try Self.decode(
            """
            version = 1

            [mutation]
            profile = "strong"
            extreme = false
            include = ["Sources/**/*.swift"]
            exclude = ["**/*.generated.swift"]
            operators = ["comparison", "optional-handling"]

            [test]
            timeout = "90s"
            baseline_runs = 5

            [execution]
            jobs = 4

            [cache]
            mode = "on"

            [policy]
            strict = true
            minimum_score = 70

            [report]
            directory = "build/mutation"
            formats = ["json"]
            high = 90
            low = 50
            """
        )
        #expect(configuration.mutation.profile == .strong)
        // `false`, because `true` is refused: whole-body replacement is not in this build.
        // This fixture used to say `true` and assert it was read, which recorded the defect
        // as though it were the specification. See `UnbuiltSettingTests`.
        #expect(configuration.mutation.extreme == false)
        #expect(configuration.mutation.include.map(\.description) == ["Sources/**/*.swift"])
        #expect(configuration.mutation.operators == ["comparison", "optional-handling"])
        #expect(configuration.test.timeout == .seconds(90))
        #expect(configuration.test.baselineRuns == 5)
        #expect(configuration.execution.jobs == 4)
        #expect(configuration.cache.mode == .enabled)
        #expect(configuration.policy.strict)
        #expect(configuration.policy.minimumScore == 70)
        #expect(configuration.report.formats == [.json])
        #expect(configuration.report.high == 90)
    }

    /// The payoff of a reader that remembers where things were written.
    @Test("refuses a key it does not know, and says where it is")
    func refusesAnUnknownKey() {
        do {
            _ = try Self.decode(
                """
                [mutation]
                profile = "balanced"
                profil = "balanced"
                """
            )
            Issue.record("the unknown key was accepted")
        } catch let failure as ConfigurationError {
            #expect(failure.line == 3, "\(failure)")
            #expect(failure.description.contains("profil"), "\(failure)")
            #expect(failure.description.contains("mutation"), "\(failure)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("refuses a table it does not know")
    func refusesAnUnknownTable() {
        do {
            _ = try Self.decode(
                """
                [mutation]
                profile = "balanced"

                [mutations]
                profile = "strong"
                """
            )
            Issue.record("the unknown table was accepted")
        } catch let failure as ConfigurationError {
            #expect(failure.line == 4, "\(failure)")
            #expect(failure.description.contains("mutations"), "\(failure)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("says what it expected and what it found")
    func refusesAValueOfTheWrongShape() {
        do {
            _ = try Self.decode(
                """
                [execution]
                jobs = "many"
                """
            )
            Issue.record("the wrong shape was accepted")
        } catch let failure as ConfigurationError {
            #expect(failure.line == 2, "\(failure)")
            #expect(failure.description.contains("an integer"), "\(failure)")
            #expect(failure.description.contains("a string"), "\(failure)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(
        "refuses a value that is not one of the ones it knows",
        arguments: [
            ("[mutation]\nprofile = \"aggressive\"", "aggressive"),
            ("[cache]\nmode = \"sometimes\"", "sometimes"),
            ("[report]\nformats = [\"pdf\"]", "pdf"),
        ]
    )
    func refusesAnUnknownEnumeratedValue(text: String, mentions: String) {
        #expect(throws: ConfigurationError.self) { try Self.decode(text) }
        do {
            _ = try Self.decode(text)
        } catch let failure as ConfigurationError {
            #expect(failure.description.contains(mentions), "\(failure)")
        } catch {}
    }

    @Test(
        "reads a duration the way it is written",
        arguments: [
            ("500ms", Duration.milliseconds(500)), ("90s", .seconds(90)), ("2m", .seconds(120)),
            ("1h", .seconds(3600)),
        ]
    )
    func readsDurations(text: String, expected: Duration) throws {
        let configuration = try Self.decode("[test]\ntimeout = \"\(text)\"")
        #expect(configuration.test.timeout == expected)
    }

    /// An expectation is evidence somebody wrote down, so it has to name a mutant that
    /// could exist and say why.
    @Test("reads the survivors a project has accounted for")
    func readsExpectations() throws {
        let identity = String(repeating: "a", count: 64)
        let configuration = try Self.decode(
            """
            [[mutation.expect]]
            id = "\(identity)"
            reason = "equivalent: the branch is unreachable for all valid inputs"
            """
        )
        #expect(configuration.mutation.expect.count == 1)
        #expect(configuration.mutation.expect.first?.reason.hasPrefix("equivalent") == true)
    }

    @Test(
        "refuses an expectation that names nothing checkable",
        arguments: [
            ("[[mutation.expect]]\nid = \"abcd\"\nreason = \"short\"", "64"),
            (
                "[[mutation.expect]]\nid = \"\(String(repeating: "a", count: 64))\"\nreason = \"\"",
                "reason"
            ),
        ]
    )
    func refusesAnIllFormedExpectation(text: String, mentions: String) {
        do {
            _ = try Self.decode(text)
            Issue.record("the expectation was accepted")
        } catch let failure as ConfigurationError {
            #expect(failure.description.contains(mentions), "\(failure)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("refuses two expectations about one mutant")
    func refusesDuplicateExpectations() {
        let identity = String(repeating: "a", count: 64)
        #expect(throws: ConfigurationError.self) {
            try Self.decode(
                """
                [[mutation.expect]]
                id = "\(identity)"
                reason = "one"

                [[mutation.expect]]
                id = "\(identity)"
                reason = "two"
                """
            )
        }
    }

    /// A version this build does not know is a configuration written for a different tool,
    /// and reading it with today's meanings would be reading it wrong.
    @Test("refuses a version it was not written for")
    func refusesAnUnknownVersion() {
        #expect(throws: ConfigurationError.self) { try Self.decode("version = 2") }
    }

    @Test("refuses a glob it could not have matched with")
    func refusesAMalformedGlob() {
        #expect(throws: ConfigurationError.self) {
            try Self.decode("[mutation]\ninclude = [\"a**b\"]")
        }
    }
}
