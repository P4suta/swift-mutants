// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// Properties the glob engine holds for every input, not only for the ones somebody wrote
/// an example of.
///
/// Each case is generated from a seed that is printed with any failure, so a case that
/// fails can be re-run rather than hunted for.
@Suite("Glob properties")
struct GlobPropertyTests {

    static let alphabet = Array("abcXY_.019")

    static func path(using generator: inout DeterministicGenerator) -> [String] {
        (0..<Int.random(in: 1...5, using: &generator)).map { _ in
            String(
                (0..<Int.random(in: 1...8, using: &generator)).map { _ in
                    alphabet.randomElement(using: &generator) ?? "a"
                }
            )
        }
    }

    /// A pattern built by loosening a path can only match more, so it must still match the
    /// path it was built from. This catches the failure that matters most - a pattern that
    /// silently stops selecting a file - across shapes nobody enumerated.
    @Test("a pattern loosened from a path still matches that path", arguments: 0..<400)
    func loosenedPatternStillMatches(seed: Int) throws {
        var generator = DeterministicGenerator(seed: UInt64(seed))
        let components = Self.path(using: &generator)

        var patternComponents: [String] = []
        for component in components {
            switch Int.random(in: 0...4, using: &generator) {
            case 0: patternComponents.append(component)
            case 1: patternComponents.append("*")
            case 2: patternComponents.append(String(repeating: "?", count: component.utf8.count))
            case 3: patternComponents.append(String(component.prefix(1)) + "*")
            default: patternComponents.append("**")
            }
        }
        // A `**` that ends the pattern requires a component under it, which a loosened
        // pattern of the same length does not have.
        if patternComponents.last == "**" {
            patternComponents[patternComponents.count - 1] = "*"
        }

        let pattern = patternComponents.joined(separator: "/")
        let path = components.joined(separator: "/")
        let glob = try #require(Glob(pattern), "seed \(seed): '\(pattern)' failed to parse")
        #expect(glob.matches(path), "seed \(seed): '\(pattern)' stopped matching '\(path)'")
    }

    /// Matching is a pure function of the pattern and the path, so asking twice must give
    /// the same answer. A matcher that carried state between calls would be a matcher whose
    /// catalogue depended on the order files were walked in.
    @Test("answers the same way every time it is asked", arguments: 0..<200)
    func isDeterministic(seed: Int) throws {
        var generator = DeterministicGenerator(seed: UInt64(seed) &+ 1_000_000)
        let subject = Self.path(using: &generator).joined(separator: "/")
        let pattern = Self.path(using: &generator).joined(separator: "/")
        let glob = try #require(Glob(pattern))
        let first = glob.matches(subject)
        let second = glob.matches(subject)
        #expect(first == second, "seed \(seed)")
    }

    /// Arbitrary bytes in a pattern must either be refused or matched, never hang. The
    /// matcher's bound is the product of the two lengths; this is what would catch a change
    /// that reintroduced branching.
    @Test("terminates on arbitrary patterns", arguments: 0..<300)
    func terminatesOnArbitraryPatterns(seed: Int) {
        var generator = DeterministicGenerator(seed: UInt64(seed) &+ 2_000_000)
        let soup = Array("*?/ab.*?**//*")
        let pattern = String(
            (0..<Int.random(in: 1...24, using: &generator)).map { _ in
                soup.randomElement(using: &generator) ?? "*"
            }
        )
        let subject = String(
            (0..<Int.random(in: 1...24, using: &generator)).map { _ in
                Self.alphabet.randomElement(using: &generator) ?? "a"
            }
        )
        // The assertion is that this returns at all.
        _ = Glob(pattern)?.matches(subject)
    }
}
