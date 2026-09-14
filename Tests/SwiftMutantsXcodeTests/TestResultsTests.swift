// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

@testable import SwiftMutantsXcode

/// What a result bundle says about each test.
///
/// This is where a mutant is decided on the Xcode path, and the way it goes wrong is
/// silent. A reader that took a bundle-level `Failed` for a test would call every mutant
/// killed; one that took an unknown verdict for a pass would call every mutant a survivor.
/// Both are a score somebody believes, so this fails closed at every step: a node it does
/// not understand is a node it says nothing about, and a run it could establish nothing
/// from is a run that did not happen.
///
/// The corpus document is one `xcresulttool` actually wrote, for a run with one passing
/// test and one failing one. A hand-made fixture would fix the reader against this tool's
/// idea of the format rather than against Xcode's.
@Suite("What a result bundle says")
struct TestResultsTests {

    static var real: Data {
        let file = RepositoryGate.root
            .appending(path: "Tests/SwiftMutantsXcodeTests/Corpus/mixed-results.json")
        guard let data = try? Data(contentsOf: file) else {
            fatalError("the corpus document is missing: \(file.path)")
        }
        return data
    }

    static func results(_ json: String) throws -> TestResults {
        try TestResults(Data(json.utf8))
    }

    @Test("reads a document xcresulttool wrote")
    func readsAReal() throws {
        let results = try TestResults(Self.real)
        #expect(results.failed == ["Subject/SubjectTests/deliberate()"])
        #expect(
            results.started.sorted() == [
                "Subject/SubjectTests/boundary()", "Subject/SubjectTests/deliberate()",
            ])
    }

    /// A bundle and a plan carry a verdict of their own, and neither is a test. A reader
    /// that counted them would report a mutant killed by something that is not a test, and
    /// name it in the report as though somebody could go and look at it.
    @Test("counts only the nodes that are tests")
    func onlyTestCases() throws {
        let results = try TestResults(Self.real)
        #expect(results.started.count == 2)
        #expect(!results.started.contains { $0.contains("Subject-Package") })
    }

    /// The identifier a report will print. Taken from the URL Xcode gives rather than
    /// rebuilt from the names, because the names repeat between bundles and the URL does
    /// not - and a report that showed two different tests under one name would send
    /// somebody to the wrong file.
    @Test("names a test the way Xcode names it")
    func namesFromTheUrl() throws {
        let results = try Self.results(
            #"""
            {"testNodes": [{"nodeType": "Test Case", "result": "Passed",
              "nodeIdentifierURL": "test://com.apple.xcode/P/Bundle/thing()"}]}
            """#)
        #expect(results.started == ["P/Bundle/thing()"])
    }

    /// A verdict it does not know is not a pass. Skipped, expected failures and whatever
    /// Xcode adds next all mean "nothing was established here", and reading one as a pass
    /// is how a mutant nothing ran against comes back a survivor.
    @Test(
        "says nothing about a verdict it does not know",
        arguments: ["Skipped", "Expected Failure", "unknown", ""])
    func unknownVerdicts(_ verdict: String) throws {
        let results = try Self.results(
            """
            {"testNodes": [{"nodeType": "Test Case", "result": "\(verdict)",
              "nodeIdentifierURL": "test://com.apple.xcode/P/B/t()"}]}
            """)
        #expect(results.failed.isEmpty)
        #expect(results.started.isEmpty)
    }

    @Test("finds the tests however deeply they are nested")
    func findsThemNested() throws {
        let results = try Self.results(
            #"""
            {"testNodes": [{"nodeType": "Test Plan", "children": [
              {"nodeType": "Unit test bundle", "children": [
                {"nodeType": "Test Suite", "children": [
                  {"nodeType": "Test Case", "result": "Failed",
                   "nodeIdentifierURL": "test://com.apple.xcode/P/B/deep()"}]}]}]}]}
            """#)
        #expect(results.failed == ["P/B/deep()"])
    }

    /// A document it cannot read establishes nothing, which is not the same as a run in
    /// which nothing failed. Telling them apart is what stops a broken bundle from being
    /// read as a suite that caught nothing.
    @Test("refuses a document it cannot read", arguments: ["", "not json", "{}", "[]"])
    func refusesUnreadable(_ text: String) {
        #expect(throws: (any Error).self) { try TestResults(Data(text.utf8)) }
    }

    /// And a URL of a shape it does not recognise is one it cannot take a name out of.
    /// Using the whole string would put `test://something.else/...` in a report as though
    /// it were a test somebody could run.
    @Test(
        "says nothing about a test named in a way it does not recognise",
        arguments: ["test://something.else/P/B/t()", "P/B/t()", "test://com.apple.xcode/"])
    func unrecognisedName(_ url: String) throws {
        let results = try Self.results(
            """
            {"testNodes": [{"nodeType": "Test Case", "result": "Failed",
              "nodeIdentifierURL": "\(url)"}]}
            """)
        #expect(results.failed.isEmpty)
        #expect(results.started.isEmpty)
    }

    /// A test case with no identifier is a node this cannot name, and a finding nobody can
    /// act on is worse than none: it would appear in a report as a killer somebody cannot
    /// find.
    @Test("says nothing about a test it cannot name")
    func unnameable() throws {
        let results = try Self.results(
            #"{"testNodes": [{"nodeType": "Test Case", "result": "Failed"}]}"#)
        #expect(results.failed.isEmpty)
    }

    /// The run as a whole: something failed, or nothing did. This is what decides a mutant.
    @Test("says whether anything failed at all")
    func saysWhetherAnythingFailed() throws {
        #expect(try TestResults(Self.real).anythingFailed)
        let clean = try Self.results(
            #"""
            {"testNodes": [{"nodeType": "Test Case", "result": "Passed",
              "nodeIdentifierURL": "test://com.apple.xcode/P/B/t()"}]}
            """#)
        #expect(!clean.anythingFailed)
    }
}
