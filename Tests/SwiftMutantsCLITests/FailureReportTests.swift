// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsDiagnostics
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsCLI

/// What a failed run leaves behind.
///
/// A run that fails an hour in has told somebody one line about why, and that line is
/// almost never enough: the question is what it was doing, what it ran, what the compiler
/// said, and whether the machine is even set up for it. All of that existed while the run
/// was alive and is gone the moment it is not.
///
/// The recording was already being kept - every subprocess passes through one place that
/// writes it down - and nothing was reading it back out. This is the part that does.
@Suite("What a failed run leaves behind")
struct FailureReportTests {

    struct Fixture {
        let root: URL
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }

    static func recorder() -> TraceRecorder {
        let recorder = TraceRecorder()
        _ = recorder.record(.runStarted(runIdentifier: "r1", toolVersion: "0.0.0-dev"))
        return recorder
    }

    @Test("writes the failure down where somebody can read it")
    func writesTheFailure() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let written = try #require(
            FailureReport.write(
                "the package does not build",
                recorder: Self.recorder(),
                environment: ["PATH": "/usr/bin"],
                keptAt: nil,
                into: fixture.root
            ))

        let error = try String(
            contentsOf: written.appending(path: DiagnosticsBundle.errorFileName), encoding: .utf8)
        #expect(error.contains("the package does not build"))
    }

    /// A bundle is something people attach to a bug report, and a value that reached this
    /// run would otherwise reach the report. The names are the useful half anyway.
    @Test("writes the names of the environment and none of the values")
    func namesOnly() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let written = try #require(
            FailureReport.write(
                "no",
                recorder: Self.recorder(),
                environment: ["SECRET_TOKEN": "hunter2"],
                keptAt: nil,
                into: fixture.root
            ))

        let text = try String(
            contentsOf: written.appending(path: "environment.txt"), encoding: .utf8)
        #expect(text.contains("SECRET_TOKEN"))
        #expect(!text.contains("hunter2"))
    }

    /// The recording is the whole point: what it ran, in order, with what it exited.
    @Test("writes down what the run did")
    func writesTheRecording() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let written = try #require(
            FailureReport.write(
                "no",
                recorder: Self.recorder(),
                environment: [:],
                keptAt: nil,
                into: fixture.root
            ))
        #expect(
            FileManager.default.fileExists(atPath: written.appending(path: "trace.jsonl").path))
    }

    /// A bundle nobody was told about is a bundle nobody has.
    @Test("says where it put it")
    func saysWhereItIs() {
        let said = Narration.diagnosed(URL(filePath: "/tmp/diagnostics/run-1"))
        #expect(said.contains("/tmp/diagnostics/run-1"))
    }

    /// The tree a run was working in, when it was kept, is the other half of the story -
    /// the bundle says what happened and the tree is where it happened.
    @Test("points at the copy when one was kept")
    func pointsAtTheCopy() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let written = try #require(
            FailureReport.write(
                "no",
                recorder: Self.recorder(),
                environment: [:],
                keptAt: URL(filePath: "/tmp/kept-tree"),
                into: fixture.root
            ))
        let text = try String(
            contentsOf: written.appending(path: DiagnosticsBundle.completionFileName),
            encoding: .utf8)
        #expect(text.contains("/tmp/kept-tree"))
    }

    /// Failing to write a bundle must not replace the failure somebody was told about with
    /// a failure about writing a bundle.
    @Test("says nothing rather than failing when it cannot write one")
    func cannotWrite() {
        #expect(
            FailureReport.write(
                "no",
                recorder: Self.recorder(),
                environment: [:],
                keptAt: nil,
                into: URL(filePath: "/swift-mutants-nowhere-at-all/diagnostics")
            ) == nil)
    }
}
