// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsCache

/// Which build of this tool an answer came from.
///
/// Every cache key carries it, because a rule may come to mean something new or a verdict
/// may be decided differently, and an answer from one build is not evidence about another.
/// A released build says so with its version.
///
/// A development build does not. `0.0.0-dev` is the same string before and after a change to
/// the thing being developed, so a cache keyed on it would hand yesterday's answers to a
/// tool that no longer agrees with them - and the person most likely to be hurt by that is
/// whoever is changing this code, measuring it against itself, and trusting the number.
@Suite("Which build an answer came from")
struct ToolIdentityTests {

    struct Fixture {
        let directory: URL
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        func executable(_ contents: String) throws -> URL {
            let file = directory.appending(path: "tool-\(UUID().uuidString)")
            try Data(contents.utf8).write(to: file)
            return file
        }
    }

    static func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Fixture(directory: directory)
    }

    /// A released build is named by its version and nothing else. Hashing megabytes of
    /// binary to rediscover a number that is already written down would be work for
    /// nothing.
    @Test("names a released build by its version")
    func releasedBuild() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let tool = try fixture.executable("anything at all")

        #expect(ToolIdentity.of("1.2.3", at: tool) == "1.2.3")
    }

    /// A development build is named by what it is, because its version does not change when
    /// it does.
    @Test("tells two development builds apart")
    func developmentBuilds() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }

        let before = ToolIdentity.of("0.0.0-dev", at: try fixture.executable("one"))
        let after = ToolIdentity.of("0.0.0-dev", at: try fixture.executable("another"))
        #expect(before != after)
        #expect(before.hasPrefix("0.0.0-dev"))
    }

    @Test("gives the same development build the same name twice")
    func sameBuildSameName() throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanUp() }
        let tool = try fixture.executable("the same bytes")

        let asked = ToolIdentity.of("0.0.0-dev", at: tool)
        let askedAgain = ToolIdentity.of("0.0.0-dev", at: tool)
        #expect(asked == askedAgain)
    }

    /// A build it cannot read is a build it cannot vouch for, so it says so rather than
    /// falling back to a version that means nothing. Two runs then never agree, which costs
    /// a cache and cannot cost an answer.
    @Test("refuses to vouch for a build it cannot read")
    func unreadableBuild() {
        let missing = URL(filePath: "/swift-mutants-nowhere/tool")
        let first = ToolIdentity.of("0.0.0-dev", at: missing)
        #expect(first.hasPrefix("0.0.0-dev"))
        #expect(first != ToolIdentity.of("0.0.0-dev", at: missing))
    }
}
