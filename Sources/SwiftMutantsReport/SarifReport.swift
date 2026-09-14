// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Survivors, in the form a code host already knows how to show.
///
/// SARIF is what GitHub's code scanning reads, and uploading one buys three things this
/// tool would otherwise have to build: a survivor annotated on the line it is about in a
/// pull request, a history of when each one appeared, and a way to dismiss one as intended.
/// The last is the important one - a mutation tool's worst failure is a list nobody can act
/// on shrinking to a list nobody reads.
///
/// Only survivors are reported. A killed mutant is not a finding, it is the tests working,
/// and a code host showing four hundred of them is a code host somebody turns off.
public struct SarifReport: Codable, Sendable, Hashable {

    /// Where the schema this follows lives.
    public static let schema =
        "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json"

    /// Which version of the format this is.
    public let version: String

    /// One run: the tool that produced it and what it found.
    public let runs: [Run]

    /// What one invocation found.
    public struct Run: Codable, Sendable, Hashable {
        /// What produced it.
        public let tool: Tool
        /// What it found.
        public let results: [Result]
    }

    /// The tool, and the rules it can report against.
    public struct Tool: Codable, Sendable, Hashable {
        /// The program itself.
        public let driver: Driver
    }

    /// The program that produced a run.
    public struct Driver: Codable, Sendable, Hashable {
        /// What it is called.
        public let name: String
        /// Which build it was.
        public let semanticVersion: String
        /// Where to read about it.
        public let informationUri: String
        /// Every rule its results may name. A code host refuses a file that names one it
        /// has not been told about.
        public let rules: [Rule]
    }

    /// One kind of finding.
    public struct Rule: Codable, Sendable, Hashable {
        /// What a result refers to it by.
        public let id: String
        /// What it is called in a list.
        public let name: String
        /// One line about it.
        public let shortDescription: Text
        /// What to do about it.
        public let fullDescription: Text
    }

    /// One finding.
    public struct Result: Codable, Sendable, Hashable {
        /// Which rule it is an instance of.
        public let ruleId: String
        /// How loudly to say it. Always `warning`: the run answered.
        public let level: String
        /// What a person reads.
        public let message: Text
        /// Where it is.
        public let locations: [Location]
        /// What makes it the same finding as one from another run.
        public let partialFingerprints: [String: String]
    }

    /// Some words.
    public struct Text: Codable, Sendable, Hashable {
        /// The words.
        public let text: String
    }

    /// Where a finding is.
    public struct Location: Codable, Sendable, Hashable {
        /// The place in a file.
        public let physicalLocation: PhysicalLocation
    }

    /// A file and a region of it.
    public struct PhysicalLocation: Codable, Sendable, Hashable {
        /// Which file.
        public let artifactLocation: ArtifactLocation
        /// Which part of it.
        public let region: Region
    }

    /// A file, named the way the repository names it.
    public struct ArtifactLocation: Codable, Sendable, Hashable {
        /// The path, relative to the repository root.
        public let uri: String
    }

    /// A part of a file, counted from one.
    public struct Region: Codable, Sendable, Hashable {
        /// The line it starts on.
        public let startLine: Int
        /// The column it starts at.
        public let startColumn: Int
    }

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version, runs
    }

    private let schemaURL: String

    /// Writes it, with the schema's own key for where the schema lives.
    ///
    /// Hand-written because `$schema` is not a name Swift will give a property, and a
    /// reader that did not find it would be a reader that did not know what it was holding.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaURL, forKey: .schema)
        try container.encode(version, forKey: .version)
        try container.encode(runs, forKey: .runs)
    }

    /// Reads one back, so that a round trip is a round trip.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaURL = try container.decode(String.self, forKey: .schema)
        version = try container.decode(String.self, forKey: .version)
        runs = try container.decode([Run].self, forKey: .runs)
    }
}

extension SarifReport {

    /// Which rule a survivor is reported under.
    ///
    /// Two, because they are two different findings with two different fixes and a reader
    /// filtering by rule should be able to see one without the other.
    enum Finding: String, CaseIterable {
        /// The tests ran and none of them noticed.
        case unnoticed = "swift-mutants/survived"
        /// No test reaches it at all.
        case unreached = "swift-mutants/uncovered"

        /// What it is called in a list.
        var name: String {
            switch self {
            case .unnoticed: "Surviving mutant"
            case .unreached: "Unreached mutant"
            }
        }

        /// One line about it.
        var summary: String {
            switch self {
            case .unnoticed: "A change to this code that every test still passed."
            case .unreached: "A change to this code that no test reaches at all."
            }
        }

        /// What to do about it.
        var advice: String {
            switch self {
            case .unnoticed:
                """
                One of the tests that ran here is where the missing assertion belongs. \
                `swift-mutants explain <id>` names them.
                """
            case .unreached:
                """
                Nothing executes this line, so nothing could have caught the change. \
                Either it wants a test, or the code wants deleting.
                """
            }
        }
    }

    /// Projects a run's own report.
    public init(of report: RunReport) {
        self.schemaURL = Self.schema
        self.version = "2.1.0"
        let found = report.mutants.filter { $0.outcome == "survived" }
        self.runs = [
            Run(
                tool: Tool(
                    driver: Driver(
                        name: "swift-mutants",
                        semanticVersion: report.tool.version,
                        informationUri: "https://github.com/P4suta/swift-mutants",
                        rules: Finding.allCases.map {
                            Rule(
                                id: $0.rawValue,
                                name: $0.name,
                                shortDescription: Text(text: $0.summary),
                                fullDescription: Text(text: $0.advice)
                            )
                        }
                    )
                ),
                results: found.map(Self.result(of:))
            )
        ]
    }

    /// One survivor as a finding.
    ///
    /// The fingerprint is the mutant's identity, which is content-addressed: it survives a
    /// file moving and a line being added above it. That is what lets a code host say "this
    /// is the one you dismissed last week" rather than showing it again.
    static func result(of mutant: RunReport.Mutant) -> Result {
        let finding: Finding = mutant.testsStarted == 0 ? .unreached : .unnoticed
        return Result(
            ruleId: finding.rawValue,
            // A warning, not an error. The run answered; a code host that failed a build
            // over an answer is a code host somebody turns off.
            level: "warning",
            message: Text(
                text: """
                    \(mutant.original) -> \(mutant.replacement) (\(mutant.rule)) survived. \
                    \(finding.summary)
                    """),
            locations: [
                Location(
                    physicalLocation: PhysicalLocation(
                        artifactLocation: ArtifactLocation(uri: mutant.path),
                        region: Region(
                            startLine: mutant.line.value ?? 1,
                            startColumn: mutant.column.value ?? 1
                        )
                    ))
            ],
            partialFingerprints: ["swiftMutantsIdentity/v1": mutant.id]
        )
    }

    /// The report as bytes, the same bytes every time.
    public static func encoded(_ report: Self) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try encoder.encode(report)
    }
}
