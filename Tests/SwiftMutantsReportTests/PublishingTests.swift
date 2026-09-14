// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsReport

/// Writing the documents a run was asked for.
///
/// These go into the repository, which is the one place this tool otherwise never writes.
/// That is deliberate and it is the user's decision: a report is something they commit,
/// publish, or hand to a code host, and it is no use to them in a cache directory they
/// cannot find.
@Suite("Publishing")
struct PublishingTests {

    struct Fixture {
        let root: URL
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-publish-\(UUID().uuidString)")
        let file = root.appending(path: "Sources/Codec/Header.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(RunReportTests.Fixture.source.utf8).write(to: file)
        return Fixture(root: root)
    }

    static func published(
        _ formats: Set<ReportFormat>, at root: URL
    ) throws -> [URL] {
        try Publishing.write(
            RunReportTests.report(results: [RunReportTests.Fixture.result(.survived, tests: [])]),
            formats: formats,
            into: root
        )
    }

    @Test("writes nothing when nothing was asked for")
    func nothingAsked() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        #expect(try Self.published([], at: fixture.root).isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "reports").path))
    }

    @Test(
        "writes the document it was asked for, and says where",
        arguments: [
            (ReportFormat.json, "reports/mutation/mutation.json"),
            (.sarif, "reports/mutation/mutation.sarif"),
            (.html, "reports/mutation/mutation.html"),
        ]
    )
    func writesWhatItWasAsked(_ format: ReportFormat, _ path: String) throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let written = try Self.published([format], at: fixture.root)
        #expect(written.map { $0.path } == [fixture.root.appending(path: path).path])
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: path).path))
    }

    @Test("writes every document it was asked for")
    func writesSeveral() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        #expect(try Self.published([.json, .sarif, .html], at: fixture.root).count == 3)
    }

    /// The JSON one is the Stryker projection, not this tool's own report: `--json` and
    /// `report latest` are where the canonical account comes from, and a file in somebody's
    /// repository called `mutation.json` is the one an ecosystem expects.
    @Test("writes the projection an ecosystem reads")
    func jsonIsTheProjection() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        _ = try Self.published([.json], at: fixture.root)

        let data = try Data(
            contentsOf: fixture.root.appending(path: "reports/mutation/mutation.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? String == "1.0")
    }

    /// The projection shows the code, which means reading it - and reading it is only safe
    /// if it is the code that was measured. A file that changed under the run is left out
    /// rather than shown beside a verdict about something else.
    @Test("leaves out a file that changed since it was measured")
    func changedFile() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        try Data("something else entirely\n".utf8)
            .write(to: fixture.root.appending(path: "Sources/Codec/Header.swift"))

        _ = try Self.published([.json], at: fixture.root)
        let data = try Data(
            contentsOf: fixture.root.appending(path: "reports/mutation/mutation.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["files"] as? [String: Any])?.isEmpty == true)
    }

    /// The premise: an unchanged file is shown.
    @Test("shows a file that is still what it was")
    func unchangedFile() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        _ = try Self.published([.json], at: fixture.root)

        let data = try Data(
            contentsOf: fixture.root.appending(path: "reports/mutation/mutation.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["files"] as? [String: Any])?.count == 1)
    }
}
