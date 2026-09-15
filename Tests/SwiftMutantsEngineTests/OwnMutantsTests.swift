// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing
@testable import SwiftMutantsEngine

extension ListerTests {

    /// A project's own mutant in the catalogue `list` prints.
    ///
    /// The run gets its own from the validation's discovery, so a listing that forgot them
    /// would still measure them - and `list`, which is what somebody reads before agreeing
    /// to an hour, would show a catalogue the run does not have. Found by perturbing the
    /// listing and watching nothing fail.
    @Test("puts a project's own mutants in the catalogue it prints")
    func listsOwnMutants() async throws {
        let fixture = try Self.fixture(
            ["Sources/Core/Rank.swift": "func f(_ a: [Int]) -> [Int] { return a.sorted() }"],
            describing: """
                {"name":"Core","type":"library","path":"$ROOT/Sources/Core",
                 "sources":["Rank.swift"]}
                """
        )
        defer { fixture.cleanUp() }

        var configuration = Configuration()
        configuration.mutation.custom = [
            Configuration.Custom(
                file: "Sources/Core/Rank.swift",
                find: "a.sorted()",
                replace: "a",
                reason: "is the sort load-bearing"
            )
        ]
        let listing = try await Self.list(fixture, configuration: configuration)
        #expect(listing.catalog.mutants.contains { $0.rule.name == "custom" })
    }

    /// And says so when one's anchor is not there any more, rather than listing a smaller
    /// catalogue and leaving somebody to notice.
    @Test("says when a project's own mutant has nothing to anchor to")
    func listsAStaleAnchor() async throws {
        let fixture = try Self.fixture(
            ["Sources/Core/Rank.swift": "func f(_ a: [Int]) -> [Int] { return a.sorted() }"],
            describing: """
                {"name":"Core","type":"library","path":"$ROOT/Sources/Core",
                 "sources":["Rank.swift"]}
                """
        )
        defer { fixture.cleanUp() }

        var configuration = Configuration()
        configuration.mutation.custom = [
            Configuration.Custom(
                file: "Sources/Core/Rank.swift",
                find: "a.deduplicated()",
                replace: "a",
                reason: "hold frames until the memory runs out"
            )
        ]
        let listing = try await Self.list(fixture, configuration: configuration)
        #expect(!listing.catalog.mutants.contains { $0.rule.name == "custom" })
        #expect(listing.skips.contains { $0.skip.reason == .customAnchorNotFound })
    }
}

/// A project's own mutants reaching the catalogue.
///
/// The discovery tests fix that an anchor is found; this fixes that a row written in a
/// project's configuration reaches the file it names and no other. A family that generated
/// perfectly and was wired to nothing would pass every test above this one.
@Suite("A project's own mutants reach the catalogue")
struct OwnMutantsTests {

    static func path(_ rendered: String) -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath(rendered) else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func configuration(_ rows: [Configuration.Custom]) -> Configuration {
        var configuration = Configuration()
        configuration.mutation.custom = rows
        return configuration
    }

    static let row = Configuration.Custom(
        file: "Sources/A.swift",
        find: "wrong.sorted()",
        replace: "wrong",
        reason: "is the sort load-bearing"
    )

    @Test("hands a file the rows that name it")
    func handsTheRightRows() {
        let own = Lister.own(of: Self.path("Sources/A.swift"), in: Self.configuration([Self.row]))
        #expect(own.count == 1)
        #expect(own.first?.find == "wrong.sorted()")
        #expect(own.first?.reason == "is the sort load-bearing")
    }

    /// And not another file's. A row applied to every file would anchor wherever the text
    /// happened to appear, which is a mutant nobody wrote.
    @Test("hands a file no row that names another")
    func notAnotherFilesRows() {
        #expect(
            Lister.own(of: Self.path("Sources/B.swift"), in: Self.configuration([Self.row])).isEmpty
        )
    }

    @Test("hands a file nothing when the project wrote none")
    func noneAtAll() {
        #expect(Lister.own(of: Self.path("Sources/A.swift"), in: Self.configuration([])).isEmpty)
    }

    /// Every field the anchor needs survives the crossing, the reason included - it is what
    /// a message about a stale anchor has to say.
    @Test("carries the line and the reason across")
    func carriesEverything() throws {
        var row = Self.row
        row.line = 42
        let own = try #require(
            Lister.own(of: Self.path("Sources/A.swift"), in: Self.configuration([row])).first)
        #expect(own.line == 42)
        #expect(own.replace == "wrong")
        #expect(own.reason == "is the sort load-bearing")
    }
}
