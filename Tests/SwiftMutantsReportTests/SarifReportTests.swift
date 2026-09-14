// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsReport

/// Survivors, in the form a code host already knows how to show.
///
/// SARIF is what GitHub's code scanning reads, and uploading one buys three things this
/// tool would otherwise have to build: a survivor annotated on the line it is about in a
/// pull request, a history of when each one appeared, and a button for dismissing one as
/// intended. The last is the important one - a mutation tool's worst failure mode is a list
/// nobody can act on shrinking to a list nobody reads.
///
/// Only survivors are reported. A killed mutant is not a finding; it is the tests working,
/// and a code host that showed four hundred of them would be a code host somebody turns
/// off.
@Suite("The SARIF projection")
struct SarifReportTests {

    static func report(_ results: [(Outcome, [String])]) -> RunReport {
        RunReportTests.report(
            results: results.map { RunReportTests.Fixture.result($0.0, tests: $0.1) })
    }

    static func object(_ report: RunReport) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: try SarifReport.encoded(SarifReport(of: report)))
                as? [String: Any])
    }

    static func results(_ report: RunReport) throws -> [[String: Any]] {
        let runs = try #require(try Self.object(report)["runs"] as? [[String: Any]])
        return try #require(runs.first?["results"] as? [[String: Any]])
    }

    @Test("says which version of the format it is")
    func saysItsVersion() throws {
        let json = try Self.object(Self.report([(.survived, [])]))
        #expect(json["version"] as? String == "2.1.0")
        #expect((json["$schema"] as? String)?.contains("sarif") == true)
    }

    @Test("says which tool made it")
    func saysWhoMadeIt() throws {
        let runs = try #require(
            try Self.object(Self.report([(.survived, [])]))["runs"] as? [[String: Any]])
        let driver = try #require(
            (runs.first?["tool"] as? [String: Any])?["driver"] as? [String: Any])
        #expect(driver["name"] as? String == "swift-mutants")
        #expect(driver["semanticVersion"] as? String == Version.current)
    }

    /// A killed mutant is the tests working. A code host that showed four hundred of them
    /// is a code host somebody turns off.
    @Test("reports what survived and nothing else")
    func onlySurvivors() throws {
        let results = try Self.results(
            Self.report([(.killed, ["P.S/a()"]), (.survived, ["P.S/a()"]), (.rejected, [])]))
        #expect(results.count == 1)
    }

    @Test("points at the line the survivor is on")
    func pointsAtTheLine() throws {
        let results = try Self.results(Self.report([(.survived, ["P.S/a()"])]))
        let location = try #require(
            (results.first?["locations"] as? [[String: Any]])?.first?["physicalLocation"]
                as? [String: Any])
        let file = try #require(location["artifactLocation"] as? [String: Any])
        #expect(file["uri"] as? String == "Sources/Codec/Header.swift")
        let region = try #require(location["region"] as? [String: Any])
        #expect(region["startLine"] as? Int == 2)
        #expect(region["startColumn"] as? Int == 3)
    }

    /// The fingerprint is the mutant's identity, which is content-addressed and survives a
    /// file moving or a line being added above it. That is what lets a code host say "this
    /// is the one you dismissed last week" rather than showing it again.
    @Test("fingerprints a survivor by what it is, not by where it is")
    func fingerprintsByIdentity() throws {
        let results = try Self.results(Self.report([(.survived, ["P.S/a()"])]))
        let prints = try #require(results.first?["partialFingerprints"] as? [String: String])
        #expect(prints["swiftMutantsIdentity/v1"]?.count == 64)
    }

    /// The message is what somebody reads in a pull request, so it says what changed and
    /// what that means rather than naming a rule.
    @Test("says what changed and what it means")
    func saysWhatItMeans() throws {
        let results = try Self.results(Self.report([(.survived, ["P.S/a()"])]))
        let message = try #require(
            (results.first?["message"] as? [String: Any])?["text"] as? String)
        #expect(message.contains("<"))
        #expect(message.contains("<="))
        #expect(message.contains("lt-to-le@1"))
    }

    /// The two kinds of survivor are different findings with different fixes, and a reader
    /// filtering by rule should be able to see only one of them.
    @Test("tells a survivor nothing reached from one nothing noticed")
    func twoKindsOfSurvivor() throws {
        let results = try Self.results(Self.report([(.survived, []), (.survived, ["P.S/a()"])]))
        #expect(Set(results.compactMap { $0["ruleId"] as? String }).count == 2)
    }

    /// Every rule a result names has to be declared, or a code host refuses the file.
    @Test("declares every rule its results name")
    func declaresItsRules() throws {
        let report = Self.report([(.survived, []), (.survived, ["P.S/a()"])])
        let runs = try #require(try Self.object(report)["runs"] as? [[String: Any]])
        let driver = try #require(
            (runs.first?["tool"] as? [String: Any])?["driver"] as? [String: Any])
        let declared = Set(
            (driver["rules"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? [])
        let used = Set(try Self.results(report).compactMap { $0["ruleId"] as? String })
        #expect(used.isSubset(of: declared))
        #expect(!declared.isEmpty)
    }

    /// A survivor is a warning, not an error: the run answered, and a code host that failed
    /// a build over one would be a code host somebody turns off.
    @Test("reports a survivor as a warning")
    func survivorsAreWarnings() throws {
        let results = try Self.results(Self.report([(.survived, ["P.S/a()"])]))
        #expect(results.first?["level"] as? String == "warning")
    }

    @Test("writes nothing to report when nothing survived")
    func nothingSurvived() throws {
        #expect(try Self.results(Self.report([(.killed, ["P.S/a()"])])).isEmpty)
    }
}
