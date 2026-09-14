// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsXcode

/// Reading what `xcodebuild` says.
///
/// It does not say only what was asked for. `-list -json` prints a timestamped note about
/// run destinations before the document on this machine, and a reader that treated the
/// whole output as JSON would fail on every project - with a message about malformed JSON
/// rather than about the note, which is the kind of error somebody spends an afternoon on.
///
/// Observed rather than assumed: the note above is what Xcode 26.6 printed when this was
/// written, and it is why any of this exists.
@Suite("Reading what xcodebuild says")
struct XcodeOutputTests {

    static let noise = """
        2026-09-15 00:28:39.429 xcodebuild[77555:104199756] [MT] IDERunDestination: \
        Supported platforms for the buildables in the current scheme is empty.
        """

    @Test("finds the document under what xcodebuild said first")
    func findsTheDocument() throws {
        let schemes = try XcodeProject.schemes(
            in: """
                \(Self.noise)
                {
                  "workspace" : { "name" : "Fixture", "schemes" : [ "Fixture-Package" ] }
                }
                """)
        #expect(schemes == ["Fixture-Package"])
    }

    @Test("finds it when xcodebuild said nothing first")
    func findsItWithoutNoise() throws {
        let schemes = try XcodeProject.schemes(
            in: #"{"project": {"name": "F", "schemes": ["A", "B"]}}"#)
        #expect(schemes == ["A", "B"])
    }

    /// A project and a workspace say the same thing under different keys, and a tool that
    /// knew one of them would work on half of what people have.
    @Test("reads a project and a workspace alike")
    func projectAndWorkspace() throws {
        #expect(try XcodeProject.schemes(in: #"{"project": {"schemes": ["A"]}}"#) == ["A"])
        #expect(try XcodeProject.schemes(in: #"{"workspace": {"schemes": ["A"]}}"#) == ["A"])
    }

    /// Nothing to run is a thing to say, not a thing to return an empty list about: the
    /// next step would be "which scheme", and the answer would be a silence somebody has
    /// to guess at.
    @Test(
        "says so when there is nothing to run",
        arguments: ["", "not json", "{}", #"{"project":{}}"#])
    func nothingToRun(_ output: String) {
        #expect(throws: (any Error).self) { try XcodeProject.schemes(in: output) }
    }

    /// The scheme somebody meant, when they did not say.
    ///
    /// One scheme is not a choice. Several is, and guessing at one would be a run measuring
    /// a target nobody asked about - so it says what the choices are instead.
    @Test("takes the only scheme there is")
    func theOnlyScheme() throws {
        #expect(try XcodeProject.scheme(nil, among: ["Only"]) == "Only")
    }

    @Test("takes the one it was told to")
    func theNamedScheme() throws {
        #expect(try XcodeProject.scheme("B", among: ["A", "B"]) == "B")
    }

    @Test("says what the choices are rather than guessing")
    func saysTheChoices() {
        #expect(throws: (any Error).self) { try XcodeProject.scheme(nil, among: ["A", "B"]) }
    }

    /// A name that is not there is a typo, and the fix is the list.
    ///
    /// The error is bound by `#expect(throws:)` rather than by a `catch let … as …`, which
    /// crashes the SILGen cleanup pass in Swift 6.3.3 when the throw is typed. With typed
    /// throws the binding is already concrete, so the pattern bought nothing anyway.
    @Test("says what there is when it was told a name there is not")
    func namesWhatThereIs() throws {
        let error = #expect(throws: XcodeProject.Unusable.self) {
            try XcodeProject.scheme("C", among: ["A", "B"])
        }
        #expect(error?.description.contains("A") == true)
        #expect(error?.description.contains("B") == true)
    }

    /// `build-for-testing` writes one of these into the products directory, named after the
    /// scheme and the platform. Which one it wrote is not something to reconstruct from the
    /// destination - the platform in the name carries a version this tool never sees.
    @Test("finds the document build-for-testing wrote")
    func findsTheXctestrun() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-products-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Debug", "Fixture_Fixture_macosx26.5-arm64.xctestrun"] {
            try Data().write(to: directory.appending(path: name))
        }
        let found = try XcodeProject.xctestrun(in: directory)
        #expect(found.lastPathComponent == "Fixture_Fixture_macosx26.5-arm64.xctestrun")
    }

    /// None means the build did not produce what it was asked for, and that is a thing to
    /// say rather than a nil to carry: every later complaint would be about something else.
    @Test("says so when build-for-testing wrote none")
    func noXctestrun() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-products-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) { try XcodeProject.xctestrun(in: directory) }
    }

    /// More than one means the scheme has several platforms in it and the run would be
    /// about whichever this happened to sort first. Saying so beats picking.
    @Test("says so when build-for-testing wrote several")
    func severalXctestruns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-products-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["A_macosx.xctestrun", "A_iphonesimulator.xctestrun"] {
            try Data().write(to: directory.appending(path: name))
        }
        #expect(throws: (any Error).self) { try XcodeProject.xctestrun(in: directory) }
    }
}
