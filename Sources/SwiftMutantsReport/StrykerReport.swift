// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsSchemas
public import Foundation
import SwiftMutantsCore

/// The report an ecosystem reads.
///
/// Mutation testing has one interchange format that anything else understands - the schema
/// the Stryker family publishes - and honouring it is what makes this tool's answers
/// legible to a dashboard, a pull-request comment, or somebody who has seen one before.
///
/// A one-way projection, and not the canonical thing. Several distinctions this tool makes
/// have nowhere to go: a confirmed timeout and a first one, a mutant the compiler refused
/// and one this tool broke on, a run narrowed to what changed. Each is written as the
/// nearest state the schema has, and those choices are made in one place
/// (``status(of:reached:)``) rather than scattered.
public struct StrykerReport: Codable, Sendable, Hashable {

    /// Where the schema this follows lives.
    public static let schema =
        "https://raw.githubusercontent.com/stryker-mutator/mutation-testing-elements/master/packages/report-schema/src/mutation-testing-report-schema.json"

    /// Which schema this is.
    public let schemaVersion: String

    /// Where a reader's dashboard draws its colours.
    ///
    /// The family's defaults, because this tool has no opinion about what score is good -
    /// only about whether the number is true.
    public let thresholds: Thresholds

    /// Which tool made it.
    public let framework: Framework

    /// Every file with mutants in it, by workspace-relative path.
    public let files: [String: File]

    /// The bands a dashboard colours by.
    public struct Thresholds: Codable, Sendable, Hashable {
        /// At or above this, a score is shown as good.
        public let high: Int
        /// Below this, a score is shown as poor.
        public let low: Int
    }

    /// Which tool made a report.
    public struct Framework: Codable, Sendable, Hashable {
        /// Always `swift-mutants`.
        public let name: String
        /// The build that produced it.
        public let version: String
    }

    /// One file, and everything that was done to it.
    public struct File: Codable, Sendable, Hashable {
        /// Always `swift`, which is what a viewer highlights by.
        public let language: String
        /// The file as it was measured.
        public let source: String
        /// What was done to it.
        public let mutants: [Mutant]
    }

    /// One mutant, in the schema's vocabulary.
    public struct Mutant: Codable, Sendable, Hashable {
        /// The whole identity, so a mutant can be followed between runs.
        public let id: String
        /// Which rule produced it, versioned.
        public let mutatorName: String
        /// What it puts there instead.
        public let replacement: String
        /// Where it is, in lines and characters.
        public let location: Location
        /// What became of it.
        public let status: String
        /// The tests that reached it.
        public let coveredBy: [String]
        /// The tests that caught it.
        public let killedBy: [String]
        /// How many tests ran with it awake.
        public let testsCompleted: Int
    }

    /// A half-open range of the file, counted in lines and characters from one.
    public struct Location: Codable, Sendable, Hashable {
        /// Where it starts.
        public let start: Place
        /// Where it ends, exclusive.
        public let end: Place
    }

    /// One place in a file.
    public struct Place: Codable, Sendable, Hashable {
        /// The line, counted from one.
        public let line: Int
        /// The column, counted from one, in characters.
        public let column: Int
    }

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case schemaVersion, thresholds, framework, files
    }

    /// Written so the key is there; read back so a round trip is a round trip.
    private let schemaURL: String

    /// Writes it, with the schema's own key for where the schema lives.
    ///
    /// Hand-written because `$schema` is not a name Swift will give a property, and a
    /// reader that did not find it would be a reader that did not know what it was holding.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaURL, forKey: .schema)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(thresholds, forKey: .thresholds)
        try container.encode(framework, forKey: .framework)
        try container.encode(files, forKey: .files)
    }

    /// Reads one back, so that a round trip is a round trip.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaURL = try container.decode(String.self, forKey: .schema)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        thresholds = try container.decode(Thresholds.self, forKey: .thresholds)
        framework = try container.decode(Framework.self, forKey: .framework)
        files = try container.decode([String: File].self, forKey: .files)
    }
}

extension StrykerReport {

    /// Projects a run's own report, given the sources it was measured against.
    ///
    /// A file whose source nobody could produce is left out rather than written with an
    /// empty one: an empty source renders as a file with no code in it and the mutants
    /// hanging off nothing, which reads as a bug in the package rather than in the report.
    public init(of report: RunReport, sources: [String: String]) {
        self.schemaURL = Self.schema
        self.schemaVersion = "1.0"
        self.thresholds = Thresholds(high: 80, low: 60)
        self.framework = Framework(name: "swift-mutants", version: report.tool.version)

        var byFile: [String: [Mutant]] = [:]
        for mutant in report.mutants where sources[mutant.path] != nil {
            let reached = mutant.ran.compactMap {
                report.tests.indices.contains($0) ? report.tests[$0] : nil
            }
            byFile[mutant.path, default: []].append(
                Mutant(
                    id: mutant.id,
                    mutatorName: mutant.rule,
                    replacement: mutant.replacement,
                    location: Self.location(of: mutant, in: sources[mutant.path] ?? ""),
                    status: Self.status(of: mutant.outcome, reached: !reached.isEmpty),
                    coveredBy: reached,
                    killedBy: mutant.killedBy,
                    testsCompleted: mutant.testsStarted
                ))
        }
        var found: [String: File] = [:]
        for (path, mutants) in byFile {
            guard let source = sources[path] else { continue }
            found[path] = File(language: "swift", source: source, mutants: mutants)
        }
        self.files = found
    }

    /// What became of a mutant, in the schema's vocabulary.
    ///
    /// Every line is a decision about the nearest true thing:
    ///
    /// - A survivor no test reached is `NoCoverage`, not `Survived`. The schema keeps that
    ///   distinction and so does this tool, because they are different problems.
    /// - A confirmed timeout is `Timeout`. The schema has no word for a first one, which is
    ///   why this tool never reports one: it retries on a quiet machine first.
    /// - A mutant this tool broke on is `RuntimeError`, which is the schema's word for "the
    ///   harness, not the program".
    /// - A mutant proved equivalent is `Ignored`, which is what the schema calls one that
    ///   was deliberately not counted.
    /// - Anything with no verdict is `Pending`, which is the only honest place for it.
    static func status(of outcome: String, reached: Bool) -> String {
        switch outcome {
        case "killed": "Killed"
        case "survived": reached ? "Survived" : "NoCoverage"
        case "timed-out": "Timeout"
        case "errored": "RuntimeError"
        case "rejected": "CompileError"
        case "equivalent": "Ignored"
        default: "Pending"
        }
    }

    /// Where a mutant is, in the units the schema counts in.
    ///
    /// Characters, not bytes. Everything inside this tool counts bytes, because that is
    /// what a span is and what the compiler reports; the schema and the viewer that renders
    /// it count characters, and on a line with anything but ASCII the two disagree by
    /// however many continuation bytes are to the left.
    static func location(of mutant: RunReport.Mutant, in source: String) -> Location {
        let index = LineIndex(source)
        let start = index.characterPosition(of: mutant.span.start)
        let end = index.characterPosition(of: mutant.span.end)
        return Location(
            start: Place(
                line: start?.line ?? mutant.line.value ?? 1,
                column: start?.column ?? mutant.column.value ?? 1
            ),
            end: Place(
                line: end?.line ?? start?.line ?? 1,
                column: end?.column ?? (start?.column).map { $0 + 1 } ?? 1
            )
        )
    }

    /// The report as bytes, the same bytes every time.
    public static func encoded(
        _ report: Self, checkedAgainst schema: String = Schemas.strykerProjection
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        let bytes = try encoder.encode(report)
        try Schemas.check(bytes, against: schema)
        return bytes
    }
}
