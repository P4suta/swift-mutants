// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsReport
import Testing

@testable import SwiftMutantsCLI

/// Saying it where the person who caused it is looking.
///
/// A survivor in a terminal is a survivor somebody has to go and find. The same survivor as
/// a workflow command appears on the line it is about, in the diff that introduced it, in
/// the review somebody is already reading - which is the difference between a report and a
/// thing that gets acted on.
///
/// Two forms, because a code host takes two. A `::warning` line lands on the code; a
/// markdown table in the step summary is the run's own account, and it is the one that
/// still works for a pull request from a fork.
@Suite("Annotations")
struct AnnotationTests {

    static func report(_ results: [(Outcome, [String])]) -> RunReport {
        ReportFixture.report(results)
    }

    @Test("puts a survivor on the line it is about")
    func onTheLine() {
        let lines = Annotations.workflowCommands(for: Self.report([(.survived, ["P.S/a()"])]))
        let line = lines.first ?? ""
        #expect(line.hasPrefix("::warning "))
        #expect(line.contains("file=Sources/Codec/Header.swift"))
        #expect(line.contains("line=2"))
        #expect(line.contains("col=3"))
    }

    /// A code host stops showing them after a while, so the ones it does show should be
    /// the ones worth showing, and the run should say how many it held back.
    @Test("stops before a code host does, and says it stopped")
    func stopsEarly() {
        let many = Array(repeating: (Outcome.survived, ["P.S/a()"]), count: 30)
        let lines = Annotations.workflowCommands(for: Self.report(many))
        #expect(lines.count == Annotations.most + 1)
        #expect(lines.last?.contains("\(30 - Annotations.most) more") == true)
    }

    @Test("says nothing when nothing survived")
    func nothingSurvived() {
        #expect(Annotations.workflowCommands(for: Self.report([(.killed, ["P.S/a()"])])).isEmpty)
    }

    /// A newline in a workflow command ends it, so anything with one in it has to be
    /// escaped or the rest of the message becomes the log's problem.
    @Test("escapes what would end the command early")
    func escapesTheMessage() {
        let escaped = Annotations.escaped("one\ntwo%three\rfour")
        #expect(!escaped.contains("\n"))
        #expect(!escaped.contains("\r"))
        #expect(escaped.contains("%0A"))
        #expect(escaped.contains("%25"))
    }

    /// The summary is the run's own account, and it is what a fork's pull request gets -
    /// annotations need a token that a fork does not have.
    @Test("writes a summary a person can read")
    func writesASummary() {
        let summary = Annotations.stepSummary(
            for: Self.report([
                (.killed, ["P.S/a()"]), (.survived, []),
            ]))
        #expect(summary.contains("| 50.00% |"))
        #expect(summary.contains("swift-mutants"))
        #expect(summary.contains("Sources/Codec/Header.swift"))
    }

    /// A table of four hundred rows is not a summary.
    @Test("keeps the summary to a length somebody reads")
    func summaryIsShort() {
        let many = Array(repeating: (Outcome.survived, ["P.S/a()"]), count: 60)
        let summary = Annotations.stepSummary(for: Self.report(many))
        #expect(summary.split(separator: "\n").count < 40)
        #expect(summary.contains("\(60 - Annotations.most) more"))
    }

    @Test("says plainly in the summary when nothing survived")
    func summaryWithNothing() {
        #expect(
            Annotations.stepSummary(for: Self.report([(.killed, ["P.S/a()"])]))
                .contains("Nothing survived"))
    }
}

/// Whether to say it at all.
///
/// Workflow commands are noise in a terminal - they are a syntax a code host reads, not a
/// sentence a person does - so they are written only where something reads them. That is
/// not a flag somebody has to remember: the environment says so, and the environment is
/// what is asked.
@Suite("When to annotate")
struct AnnotationEnvironmentTests {

    @Test("says nothing anywhere else")
    func notElsewhere() {
        #expect(Annotations.wanted(in: [:]) == false)
        #expect(Annotations.wanted(in: ["CI": "true"]) == false)
    }

    @Test("annotates where something reads annotations")
    func onACodeHost() {
        #expect(Annotations.wanted(in: ["GITHUB_ACTIONS": "true"]))
    }

    /// The summary goes to a file the host names, and there is nowhere to put it otherwise.
    @Test("writes a summary only where it was given somewhere to put it")
    func summaryNeedsAPlace() {
        #expect(
            Annotations.summaryFile(in: ["GITHUB_STEP_SUMMARY": "/tmp/out"])?.path == "/tmp/out")
        #expect(Annotations.summaryFile(in: [:]) == nil)
        #expect(Annotations.summaryFile(in: ["GITHUB_STEP_SUMMARY": ""]) == nil)
    }
}
