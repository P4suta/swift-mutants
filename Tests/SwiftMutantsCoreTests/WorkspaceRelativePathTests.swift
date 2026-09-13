// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// The only kind of path a mutant identity is allowed to contain.
///
/// Discovery reads the user's own tree; every build, edit and test happens inside a
/// disposable snapshot at some temporary location. The same mutant therefore has two
/// absolute paths, and a third if somebody moves the checkout. An identity built from any
/// of them would change for reasons that have nothing to do with the program, taking the
/// outcome cache, the recorded expectations and the shard assignment with it.
///
/// So the type refuses to hold an absolute path at all. The invariant is not a rule
/// somebody has to remember at each call site; it is the only thing the initialiser will
/// accept.
@Suite("Workspace-relative path")
struct WorkspaceRelativePathTests {

    @Test("keeps an ordinary relative path")
    func keepsRelativePath() throws {
        let path = try #require(WorkspaceRelativePath("Sources/Foo/Bar.swift"))
        #expect(path.rendered == "Sources/Foo/Bar.swift")
        #expect(path.components == ["Sources", "Foo", "Bar.swift"])
    }

    @Test(
        "normalises spellings that name the same file",
        arguments: [
            "./Sources/Bar.swift",
            "Sources//Bar.swift",
            "Sources/./Bar.swift",
            "Sources/Foo/../Bar.swift",
            "Sources\\Bar.swift",
        ]
    )
    func normalisesEquivalentSpellings(spelling: String) throws {
        #expect(try #require(WorkspaceRelativePath(spelling)).rendered == "Sources/Bar.swift")
    }

    /// The separator is `/` on every platform, because the identity has to be the same
    /// whichever machine computed it. A Windows spelling is accepted and normalised rather
    /// than refused, since it is what a path from a Windows toolchain looks like.
    @Test("renders with forward slashes whatever it was given")
    func rendersPortably() throws {
        #expect(try #require(WorkspaceRelativePath("a\\b\\c")).rendered == "a/b/c")
    }

    @Test(
        "refuses an absolute path",
        arguments: ["/Users/x/Sources/Bar.swift", "/", "C:/Sources/Bar.swift", "C:\\Sources"]
    )
    func refusesAbsolutePath(spelling: String) {
        #expect(WorkspaceRelativePath(spelling) == nil)
    }

    /// A path that climbs out of the workspace names something the run does not own, and
    /// resolves differently from inside a snapshot than from the workspace it was copied
    /// from.
    @Test("refuses a path that escapes the workspace", arguments: ["..", "../x", "a/../../b"])
    func refusesEscapingPath(spelling: String) {
        #expect(WorkspaceRelativePath(spelling) == nil)
    }

    @Test("refuses a path that names nothing", arguments: ["", ".", "./", "a/.."])
    func refusesEmptyPath(spelling: String) {
        #expect(WorkspaceRelativePath(spelling) == nil)
    }

    @Test("orders by component so a catalogue sorts the same way everywhere")
    func ordering() throws {
        let paths = try ["b/a.swift", "a/z.swift", "a/a.swift"].map {
            try #require(WorkspaceRelativePath($0))
        }
        #expect(paths.sorted().map(\.rendered) == ["a/a.swift", "a/z.swift", "b/a.swift"])
    }

    @Test("encodes as its rendered string")
    func codableRoundTrip() throws {
        let path = try #require(WorkspaceRelativePath("Sources/Bar.swift"))
        let json = try JSONTestSupport.canonicalJSON(of: ["p": path])
        #expect(json == #"{"p":"Sources/Bar.swift"}"#)
        #expect(
            try JSONTestSupport.decode([String: WorkspaceRelativePath].self, from: json)["p"]
                == path)
    }

    @Test("refuses to decode a path it would have refused to build")
    func refusesToDecodeAbsolutePath() {
        #expect(throws: (any Error).self) {
            try JSONTestSupport.decode(WorkspaceRelativePath.self, from: #""/etc/passwd""#)
        }
    }

    /// Two spellings of one file must not become two identities.
    @Test("equates spellings that normalise to the same components")
    func equatesEquivalentSpellings() throws {
        #expect(
            try #require(WorkspaceRelativePath("./a/b.swift"))
                == #require(WorkspaceRelativePath("a//b.swift"))
        )
    }
}
