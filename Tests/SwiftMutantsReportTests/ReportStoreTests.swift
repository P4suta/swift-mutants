// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsReport

/// Keeping a run's account of itself after the run is over.
///
/// A mutation run takes long enough that nobody runs it again to look something up, so the
/// report has to outlive the terminal it scrolled past. It is kept outside the repository,
/// because the first rule of this tool is that the workspace it was pointed at is only ever
/// read - a report written into somebody's tree would be the tool changing the thing it was
/// measuring.
@Suite("Keeping a report")
struct ReportStoreTests {

    static func report() -> RunReport {
        RunReportTests.report(results: [RunReportTests.Fixture.result(.survived, tests: [])])
    }

    @Test("comes back the way it went in")
    func roundTrips() throws {
        let store = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }

        try ReportStore.write(Self.report(), to: store.appending(path: "latest.json"))
        let again = try #require(ReportStore.read(from: store.appending(path: "latest.json")))
        #expect(again == Self.report())
    }

    @Test("writes into a directory that was not there")
    func makesTheDirectory() throws {
        let store = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }

        try ReportStore.write(Self.report(), to: store.appending(path: "deep/latest.json"))
        #expect(
            FileManager.default.fileExists(atPath: store.appending(path: "deep/latest.json").path))
    }

    /// Nothing there is not an error: nobody has run it yet, and the command that asks has
    /// to be able to say so rather than fail.
    @Test("has nothing to say before the first run")
    func nothingYet() {
        #expect(
            ReportStore.read(
                from: FileManager.default.temporaryDirectory.appending(path: "swift-mutants-no"))
                == nil
        )
    }

    /// And a file it cannot read is the same as none. A report half-written by an
    /// interrupted run is not a smaller report, it is a wrong one.
    @Test("has nothing to say about a file it cannot read", arguments: ["", "{", "{\"a\":1}"])
    func nothingUsable(_ contents: String) throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(contents.utf8).write(to: file)

        #expect(ReportStore.read(from: file) == nil)
    }

    /// Outside the repository, and one place per package so two do not overwrite each
    /// other's answers.
    @Test("keeps a package's reports outside it, and apart from another's")
    func livesElsewhere() {
        let one = ReportStore.location(for: URL(filePath: "/work/alpha"))
        let other = ReportStore.location(for: URL(filePath: "/work/beta"))
        #expect(one != other)
        #expect(!one.path.hasPrefix("/work/alpha"))
    }
}
