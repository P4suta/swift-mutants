// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsXcode

/// The file that says what `xcodebuild test-without-building` will run.
///
/// It is where a mutant is woken on the Xcode path. There is no argument for handing an
/// environment variable to `test-without-building`, so the variable goes into the document
/// instead - once per test target, because a scheme with three of them runs three processes
/// and a variable set on one of them would wake the mutant in a third of the run.
///
/// Read and written as a property list, never by editing text. A `.xctestrun` holds paths
/// with spaces in them, arrays, nested dictionaries and a format version, and a tool that
/// rewrote it with string replacement would work until the first project that had any of
/// those - which is every real project.
@Suite("The document that says what to run")
struct XctestrunTests {

    /// One test target, which is the shape everything here is about.
    static func document(
        targets: Int = 1, environment: [String: String] = ["TERM": "dumb"]
    ) -> [String: Any] {
        [
            "__xctestrun_metadata__": ["FormatVersion": 2],
            "ContainerInfo": ["ContainerName": "Fixture", "SchemeName": "Fixture-Package"],
            "TestConfigurations": [
                [
                    "Name": "Test Scheme Action",
                    "TestTargets": (0..<targets).map { index in
                        [
                            "BlueprintName": "Target\(index)",
                            "EnvironmentVariables": environment,
                            "TestBundlePath": "__TESTROOT__/Debug/Target\(index).xctest",
                        ] as [String: Any]
                    },
                ] as [String: Any]
            ],
        ]
    }

    static func written(_ document: [String: Any]) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-xctestrun-\(UUID().uuidString).xctestrun")
        try PropertyListSerialization
            .data(fromPropertyList: document, format: .xml, options: 0)
            .write(to: file)
        return file
    }

    static func read(_ file: URL) throws -> Xctestrun {
        try Xctestrun(contentsOf: file)
    }

    @Test("reads a document xcodebuild wrote")
    func readsOne() throws {
        let file = try Self.written(Self.document())
        defer { try? FileManager.default.removeItem(at: file) }
        let document = try Self.read(file)
        #expect(document.formatVersion == 2)
        #expect(document.testTargetNames == ["Target0"])
    }

    /// A shape it does not know is a shape it must not guess at. Waking a mutant in a
    /// document it misread would be a run whose every answer is about a program with
    /// nothing awake - which reads as a suite that catches nothing.
    @Test("refuses a document of a version it does not know")
    func refusesAnUnknownVersion() throws {
        var document = Self.document()
        document["__xctestrun_metadata__"] = ["FormatVersion": 99]
        let file = try Self.written(document)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try Self.read(file) }
    }

    @Test("refuses a document with no test targets in it")
    func refusesAnEmptyDocument() throws {
        let file = try Self.written(Self.document(targets: 0))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try Self.read(file) }
    }

    @Test("refuses a file that is not a property list at all")
    func refusesNonsense() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-\(UUID().uuidString).xctestrun")
        try Data("not a plist".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try Self.read(file) }
    }

    /// The whole point: a copy that wakes one mutant, leaving the original alone.
    @Test("writes a copy that wakes one mutant")
    func wakesOne() throws {
        let file = try Self.written(Self.document())
        defer { try? FileManager.default.removeItem(at: file) }
        let copy = try Self.read(file).waking(["SWIFT_MUTANTS_ACTIVE": "7"])
        #expect(copy.environment(ofTarget: "Target0")?["SWIFT_MUTANTS_ACTIVE"] == "7")
        // And the original is untouched, which is what lets one build serve every mutant.
        #expect(
            try Self.read(file).environment(ofTarget: "Target0")?["SWIFT_MUTANTS_ACTIVE"] == nil)
    }

    /// Every target, not the first. A scheme with three test targets runs three processes,
    /// and a variable set on one of them would wake the mutant in a third of the run - which
    /// reads as a mutant two thirds of the suite cannot catch.
    @Test("wakes it in every test target the scheme has")
    func wakesEveryTarget() throws {
        let file = try Self.written(Self.document(targets: 3))
        defer { try? FileManager.default.removeItem(at: file) }
        let copy = try Self.read(file).waking(["SWIFT_MUTANTS_ACTIVE": "7"])
        for index in 0..<3 {
            #expect(copy.environment(ofTarget: "Target\(index)")?["SWIFT_MUTANTS_ACTIVE"] == "7")
        }
    }

    /// Xcode puts variables of its own in there - `DYLD_INSERT_LIBRARIES`, `TERM` - and a
    /// document that dropped them would run the tests in an environment Xcode did not
    /// intend, which is a different program from the one the baseline measured.
    @Test("keeps the variables xcodebuild put there")
    func keepsXcodesOwn() throws {
        let file = try Self.written(
            Self.document(environment: ["TERM": "dumb", "DYLD_INSERT_LIBRARIES": "/usr/lib/x"]))
        defer { try? FileManager.default.removeItem(at: file) }
        let copy = try Self.read(file).waking(["SWIFT_MUTANTS_ACTIVE": "7"])
        #expect(copy.environment(ofTarget: "Target0")?["TERM"] == "dumb")
        #expect(copy.environment(ofTarget: "Target0")?["DYLD_INSERT_LIBRARIES"] == "/usr/lib/x")
    }

    /// A target with no environment at all is ordinary, and it still has to be woken.
    @Test("wakes a target that had no environment of its own")
    func wakesAnEmptyTarget() throws {
        var document = Self.document()
        var configurations = try #require(document["TestConfigurations"] as? [[String: Any]])
        var targets = try #require(configurations[0]["TestTargets"] as? [[String: Any]])
        targets[0].removeValue(forKey: "EnvironmentVariables")
        configurations[0]["TestTargets"] = targets
        document["TestConfigurations"] = configurations

        let file = try Self.written(document)
        defer { try? FileManager.default.removeItem(at: file) }
        let copy = try Self.read(file).waking(["SWIFT_MUTANTS_ACTIVE": "7"])
        #expect(copy.environment(ofTarget: "Target0")?["SWIFT_MUTANTS_ACTIVE"] == "7")
    }

    /// The copy goes somewhere of this tool's choosing, never over the one xcodebuild
    /// wrote: one build serves every mutant, and a document edited in place would leave the
    /// last mutant's variable set for whatever ran next.
    @Test("writes the copy beside the original without replacing it")
    func writesACopy() throws {
        let file = try Self.written(Self.document())
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-copies-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: directory)
        }
        let written = try Self.read(file)
            .waking(["SWIFT_MUTANTS_ACTIVE": "7"])
            .write(into: directory, named: "mutant-7")
        #expect(written.lastPathComponent == "mutant-7.xctestrun")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(
            try Self.read(written).environment(ofTarget: "Target0")?["SWIFT_MUTANTS_ACTIVE"] == "7")
    }
}
