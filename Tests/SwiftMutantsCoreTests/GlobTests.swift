// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// Which files a run mutates.
///
/// Written here rather than taken from a library, for the same reason the hash is: `**`
/// means different things in different implementations, and which files were mutated
/// decides which mutants exist, which decides every identity in the catalogue. A pattern
/// has to mean the same thing on every machine and in every version, so its meaning is
/// pinned by these tests rather than by a dependency's changelog.
@Suite("Glob")
struct GlobTests {

    static func matches(_ pattern: String, _ path: String) throws -> Bool {
        try #require(Glob(pattern)).matches(path)
    }

    @Test("matches a literal path")
    func literal() throws {
        #expect(try Self.matches("Sources/Foo.swift", "Sources/Foo.swift"))
        #expect(try !Self.matches("Sources/Foo.swift", "Sources/Bar.swift"))
    }

    @Test(
        "matches any run of bytes inside one component with a star",
        arguments: [
            ("Sources/*.swift", "Sources/Foo.swift", true),
            ("Sources/*.swift", "Sources/.swift", true),
            ("Sources/*.swift", "Sources/Foo.txt", false),
            ("*/Foo.swift", "Sources/Foo.swift", true),
            ("Sources/*", "Sources/Foo.swift", true),
        ]
    )
    func starWithinComponent(pattern: String, path: String, expected: Bool) throws {
        #expect(try Self.matches(pattern, path) == expected)
    }

    /// The distinction the whole design rests on: a single star stops at a separator, so
    /// `Sources/*.swift` is about one directory and cannot quietly take a whole tree with
    /// it.
    @Test("does not let a star cross a separator")
    func starDoesNotCrossSeparator() throws {
        #expect(try !Self.matches("Sources/*.swift", "Sources/Codec/Foo.swift"))
        #expect(try !Self.matches("*", "Sources/Foo.swift"))
    }

    @Test("matches exactly one byte with a question mark")
    func questionMark() throws {
        #expect(try Self.matches("Sources/?.swift", "Sources/a.swift"))
        #expect(try !Self.matches("Sources/?.swift", "Sources/ab.swift"))
        #expect(try !Self.matches("Sources/?.swift", "Sources/.swift"))
        #expect(try !Self.matches("a/?/b", "a//b"))
    }

    @Test(
        "crosses directories with a double star",
        arguments: [
            ("Sources/**/Foo.swift", "Sources/Foo.swift", true),
            ("Sources/**/Foo.swift", "Sources/Codec/Foo.swift", true),
            ("Sources/**/Foo.swift", "Sources/Codec/Deep/Foo.swift", true),
            ("Sources/**/Foo.swift", "Tests/Codec/Foo.swift", false),
            ("**/Foo.swift", "Foo.swift", true),
            ("**/Foo.swift", "a/b/c/Foo.swift", true),
            ("Sources/**", "Sources/Codec/Foo.swift", true),
            ("**", "anything/at/all.swift", true),
        ]
    )
    func doubleStarCrossesDirectories(pattern: String, path: String, expected: Bool) throws {
        #expect(try Self.matches(pattern, path) == expected)
    }

    /// `a/**` naming `a` itself would make an exclusion of `vendor/**` leave `vendor`
    /// behind as a file, so a trailing double star requires at least the separator it
    /// follows.
    @Test("a trailing double star matches what is under a directory")
    func trailingDoubleStar() throws {
        #expect(try Self.matches("Sources/**", "Sources/Foo.swift"))
        #expect(try !Self.matches("Sources/**", "Sources"))
        #expect(try !Self.matches("Sources/**", "SourcesOther/Foo.swift"))
    }

    /// A double star that is not a whole component is not one. `a**b` would otherwise be
    /// a pattern whose meaning depends on where the reader thinks the component boundary
    /// is, and the answer would differ between implementations - which is the exact thing
    /// this engine exists to avoid.
    @Test(
        "refuses a double star that is not a whole component",
        arguments: ["a**b", "a**/b", "a/**b"])
    func refusesPartialDoubleStar(pattern: String) {
        #expect(Glob(pattern) == nil)
    }

    @Test("refuses a pattern that names nothing", arguments: ["", "/", "//"])
    func refusesEmptyPattern(pattern: String) {
        #expect(Glob(pattern) == nil)
    }

    @Test("is case sensitive, like the paths it matches")
    func caseSensitive() throws {
        #expect(try !Self.matches("sources/*.swift", "Sources/Foo.swift"))
    }

    /// A pattern of many stars against a long non-matching name is where a naive
    /// backtracking matcher takes exponential time. The matcher remembers the last star it
    /// passed instead of recursing, which bounds the work at the product of the two
    /// lengths. This test is here to fail by timing out if that ever regresses.
    @Test("terminates on the pattern that makes naive backtracking explode")
    func pathologicalPatternTerminates() throws {
        let pattern = "d/" + String(repeating: "a*", count: 24) + "b"
        let path = "d/" + String(repeating: "a", count: 120)
        #expect(try !Self.matches(pattern, path))
    }

    @Test("matches a workspace-relative path as well as a string")
    func matchesTypedPath() throws {
        let glob = try #require(Glob("Sources/**/*.swift"))
        let path = try #require(WorkspaceRelativePath("Sources/Codec/Header.swift"))
        #expect(glob.matches(path))
    }

    @Test("renders as the pattern it was built from")
    func renders() throws {
        #expect(try #require(Glob("Sources/**/*.swift")).description == "Sources/**/*.swift")
    }
}

/// Include and exclude together, which is how a run says what it mutates.
@Suite("Glob set")
struct GlobSetTests {

    static func set(include: [String], exclude: [String]) throws -> GlobSet {
        GlobSet(
            include: try include.map { try #require(Glob($0)) },
            exclude: try exclude.map { try #require(Glob($0)) }
        )
    }

    @Test("admits everything when nothing was included")
    func emptyIncludeAdmitsEverything() throws {
        let set = try Self.set(include: [], exclude: [])
        #expect(set.admits("Sources/Foo.swift"))
    }

    @Test("admits only what an include names")
    func includeNarrows() throws {
        let set = try Self.set(include: ["Sources/**"], exclude: [])
        #expect(set.admits("Sources/Foo.swift"))
        #expect(!set.admits("Tests/Foo.swift"))
    }

    /// Excludes are applied after includes, so a narrow exclusion can carve a hole in a
    /// broad inclusion and not the other way round.
    @Test("applies excludes after includes")
    func excludeWinsOverInclude() throws {
        let set = try Self.set(include: ["Sources/**"], exclude: ["Sources/Generated/**"])
        #expect(set.admits("Sources/Foo.swift"))
        #expect(!set.admits("Sources/Generated/Foo.swift"))
    }

    @Test("excludes even when nothing was included")
    func excludeAppliesWithoutInclude() throws {
        let set = try Self.set(include: [], exclude: ["**/*.generated.swift"])
        #expect(set.admits("Sources/Foo.swift"))
        #expect(!set.admits("Sources/Foo.generated.swift"))
    }
}
