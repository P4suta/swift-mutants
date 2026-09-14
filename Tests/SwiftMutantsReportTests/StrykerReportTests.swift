// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsReport

/// The report an ecosystem reads.
///
/// Mutation testing has one interchange format that anything else understands - the schema
/// the Stryker family publishes - and honouring it is what makes this tool's answers
/// legible to a dashboard, a pull-request comment, or a person who has seen one before.
///
/// It is a one-way projection and not the canonical thing. Several distinctions this tool
/// makes have no place to go: a confirmed timeout and a first one, a mutant the compiler
/// refused and one that errored, a survivor nothing reached and one nothing noticed. Every
/// one of those is written here as the nearest state the schema has, and the mapping is the
/// decision - not an accident of whichever `case` was typed first.
@Suite("The Stryker projection")
struct StrykerReportTests {

    static func report(_ results: [(Outcome, [String])] = [(.survived, [])]) -> RunReport {
        RunReportTests.report(
            results: results.map { RunReportTests.Fixture.result($0.0, tests: $0.1) })
    }

    static func object(
        _ report: RunReport,
        sources: [String: String] = ["Sources/Codec/Header.swift": "let a=1\nab< b\n"]
    ) throws -> [String: Any] {
        let data = try StrykerReport.encoded(
            StrykerReport(of: report, sources: sources))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("says which schema it is")
    func saysItsSchema() throws {
        let json = try Self.object(Self.report())
        #expect(json["schemaVersion"] as? String == "1.0")
        #expect((json["$schema"] as? String)?.contains("mutation-testing-report-schema") == true)
    }

    /// The thresholds a reader's dashboard colours by. Written because the schema requires
    /// them, and left at the family's defaults because this tool has no opinion about what
    /// score is good - only about whether the number is true.
    @Test("carries the thresholds the schema requires")
    func carriesThresholds() throws {
        let thresholds = try #require(
            try Self.object(Self.report())["thresholds"] as? [String: Any])
        #expect(thresholds["high"] as? Int == 80)
        #expect(thresholds["low"] as? Int == 60)
    }

    @Test("puts each mutant under the file it is in")
    func groupsByFile() throws {
        let files = try #require(try Self.object(Self.report())["files"] as? [String: Any])
        #expect(Array(files.keys) == ["Sources/Codec/Header.swift"])
        let file = try #require(files["Sources/Codec/Header.swift"] as? [String: Any])
        #expect(file["language"] as? String == "swift")
        #expect((file["mutants"] as? [[String: Any]])?.count == 1)
    }

    /// The source is what makes the report readable: the viewer shows the code with the
    /// mutants marked on it. Without it there is a list of line numbers.
    @Test("carries the source it was measured against")
    func carriesTheSource() throws {
        let files = try #require(try Self.object(Self.report())["files"] as? [String: Any])
        let file = try #require(files["Sources/Codec/Header.swift"] as? [String: Any])
        #expect(file["source"] as? String == "let a=1\nab< b\n")
    }

    /// A file whose source nobody could produce is left out rather than written with an
    /// empty one. An empty source renders as a file with no code in it and the mutants
    /// hanging off nothing, which reads as a bug in the package rather than in the report.
    @Test("leaves out a file it has no source for")
    func withoutASource() throws {
        let files = try #require(
            try Self.object(Self.report(), sources: [:])["files"] as? [String: Any])
        #expect(files.isEmpty)
    }

    /// Columns are characters here, not bytes. Everything inside this tool counts bytes,
    /// because that is what a span is; the schema and the viewer that renders it count
    /// characters, and on a line with anything but ASCII the two disagree.
    @Test("gives a location the schema's own units")
    func locationInCharacters() throws {
        // The mutant's span is bytes 10..<11. This source puts two `é` before it on the
        // same line, so the byte column is 7 and the character column is 5 - which is the
        // whole point: a report in the wrong unit points two columns to the left of the
        // thing it is about, and looks precise while doing it.
        let source = "aé\nbcéé< b\n"
        #expect(Array(source.utf8)[10] == UInt8(ascii: "<"))

        let json = try Self.object(Self.report(), sources: ["Sources/Codec/Header.swift": source])
        let files = try #require(json["files"] as? [String: Any])
        let file = try #require(files["Sources/Codec/Header.swift"] as? [String: Any])
        let mutant = try #require((file["mutants"] as? [[String: Any]])?.first)
        let location = try #require(mutant["location"] as? [String: Any])
        let start = try #require(location["start"] as? [String: Any])
        let end = try #require(location["end"] as? [String: Any])
        #expect(start["line"] as? Int == 2)
        #expect(start["column"] as? Int == 5, "the byte column here is 7")
        #expect(end["line"] as? Int == 2)
        #expect(end["column"] as? Int == 6)
    }

    @Test("names each mutant in full, and says what it would put there")
    func namesAndReplacement() throws {
        let files = try #require(try Self.object(Self.report())["files"] as? [String: Any])
        let file = try #require(files["Sources/Codec/Header.swift"] as? [String: Any])
        let mutant = try #require((file["mutants"] as? [[String: Any]])?.first)
        #expect((mutant["id"] as? String)?.count == 64)
        #expect(mutant["replacement"] as? String == "<=")
        #expect(mutant["mutatorName"] as? String == "lt-to-le@1")
    }

    /// The mapping, stated once. Each of these is a decision about what the nearest true
    /// thing is, not an accident.
    @Test(
        "says what became of each mutant in the schema's vocabulary",
        arguments: [
            (Outcome.killed, ["P.S/a()"], "Killed"),
            (.survived, ["P.S/a()"], "Survived"),
            (.survived, [], "NoCoverage"),
            (.timedOut, ["P.S/a()"], "Timeout"),
            (.errored, ["P.S/a()"], "RuntimeError"),
            (.equivalent, ["P.S/a()"], "Ignored"),
            (.notRun, ["P.S/a()"], "Pending"),
            (.inconclusive, ["P.S/a()"], "Pending"),
        ]
    )
    func statusVocabulary(_ outcome: Outcome, _ tests: [String], _ status: String) throws {
        let files = try #require(
            try Self.object(Self.report([(outcome, tests)]))["files"] as? [String: Any])
        let file = try #require(files["Sources/Codec/Header.swift"] as? [String: Any])
        let mutant = try #require((file["mutants"] as? [[String: Any]])?.first)
        #expect(mutant["status"] as? String == status)
    }

    /// The one distinction the schema keeps that this tool also keeps, and the one most
    /// worth keeping: a survivor nothing reached is a different problem from one nothing
    /// noticed, and `NoCoverage` says so.
    @Test("tells a survivor nothing reached from one nothing noticed")
    func twoKindsOfSurvivor() throws {
        let json = try Self.object(Self.report([(.survived, []), (.survived, ["P.S/a()"])]))
        let files = try #require(json["files"] as? [String: Any])
        let file = try #require(files["Sources/Codec/Header.swift"] as? [String: Any])
        let statuses = (file["mutants"] as? [[String: Any]])?.map { $0["status"] as? String }
        #expect(statuses == ["NoCoverage", "Survived"])
    }

    @Test("says which tests reached it and which one caught it")
    func namesTheTests() throws {
        let json = try Self.object(Self.report([(.killed, ["P.S/a()", "P.S/b()"])]))
        let files = try #require(json["files"] as? [String: Any])
        let file = try #require(files["Sources/Codec/Header.swift"] as? [String: Any])
        let mutant = try #require((file["mutants"] as? [[String: Any]])?.first)
        #expect(mutant["coveredBy"] as? [String] == ["P.S/a()", "P.S/b()"])
        #expect(mutant["killedBy"] as? [String] == ["P.S/a()", "P.S/b()"])
    }

    @Test("says which tool made it")
    func saysWhoMadeIt() throws {
        let framework = try #require(
            try Self.object(Self.report())["framework"] as? [String: Any])
        #expect(framework["name"] as? String == "swift-mutants")
        #expect(framework["version"] as? String == Version.current)
    }

    /// A file written twice must be written the same, for the same reasons a report is -
    /// and asserted as sortedness rather than as "twice is the same", because a dictionary
    /// enumerates in one order within a process and a different one in the next.
    @Test("writes its keys in one order")
    func deterministic() throws {
        let text = String(
            decoding: try StrykerReport.encoded(
                StrykerReport(
                    of: Self.report(),
                    sources: ["Sources/Codec/Header.swift": "let a=1\nab< b\n"]
                )
            ), as: UTF8.self)
        let keys = ["$schema", "files", "framework", "schemaVersion", "thresholds"]
        let places = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(places.count == keys.count)
        #expect(places == places.sorted())
    }
}
