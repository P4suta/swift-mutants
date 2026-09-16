// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// Which operators a run actually uses.
///
/// `profile` and `operators` were read out of the settings file, validated, written into
/// the file `init` produces with a comment explaining the tiers - and then used by nothing
/// at all. Setting `profile = "all"` changed no mutant, and the only way to find that out
/// was to read the source of this tool.
///
/// That is the exact failure this project exists to refuse: a setting whose not working is
/// indistinguishable from its working. Worse than an unimplemented setting, because the
/// tool itself wrote it into the user's file and told them what it meant.
///
/// A rule the tier leaves out is a **skip**, not a silence: it is named, counted and shown
/// by `why-skipped`, so "my bitwise mutants disappeared" has an answer in the tool rather
/// than in its source.
@Suite("Which operators a profile selects")
struct ProfileTests {

    static func discover(
        _ source: String,
        profile: Configuration.Profile = .balanced,
        operators: [String] = []
    ) -> FileDiscovery {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = profile
        mutation.operators = operators
        return Discover.candidates(in: source, at: path, selecting: mutation)
    }

    /// One comparison, in `balanced`, and one bitwise operator, in `strong`.
    static let source = """
        func f(_ a: Int, _ b: Int) -> Int {
            if a < b { return a & b }
            return b
        }
        """

    static func rules(_ discovery: FileDiscovery) -> Set<String> {
        Set(discovery.candidates.map(\.rule.name))
    }

    /// The fixture has to hold one of each or every assertion below is vacuous: a source
    /// with no bitwise operator in it passes "balanced leaves bitwise out" however the
    /// selection is written.
    @Test("the fixture offers both tiers when nothing narrows it")
    func fixtureHoldsBoth() {
        let everything = Self.rules(Self.discover(Self.source, profile: .all))
        #expect(everything.contains("lt-to-le"), "\(everything)")
        #expect(everything.contains("bitand-to-bitor"), "\(everything)")
    }

    @Test("balanced leaves out the tiers above it")
    func balancedIsNarrower() {
        let offered = Self.rules(Self.discover(Self.source, profile: .balanced))
        #expect(offered.contains("lt-to-le"), "\(offered)")
        #expect(!offered.contains("bitand-to-bitor"), "\(offered)")
    }

    @Test("strong takes in what balanced left out")
    func strongIsWider() {
        let offered = Self.rules(Self.discover(Self.source, profile: .strong))
        #expect(offered.contains("lt-to-le"), "\(offered)")
        #expect(offered.contains("bitand-to-bitor"), "\(offered)")
    }

    /// Named, counted, and answerable by `why-skipped`. A candidate that vanishes with no
    /// reason is the thing this tool refuses to do to anybody's package.
    @Test("says what the tier left out rather than dropping it")
    func namesWhatItLeftOut() {
        let discovery = Self.discover(Self.source, profile: .balanced)
        let outside = discovery.skips.filter { $0.reason == .outsideProfile }
        #expect(!outside.isEmpty, "\(discovery.skips.map(\.reason))")
        #expect(outside.reduce(0) { $0 + $1.candidatesHidden } >= 1)
    }

    /// "Only these operators, by name, whatever the profile says" - which is what the file
    /// `init` writes says it does.
    @Test("a named operator is the only one offered")
    func namesWin() {
        let offered = Self.rules(Self.discover(Self.source, operators: ["lt-to-le"]))
        #expect(offered == ["lt-to-le"], "\(offered)")
    }

    /// And naming one outside the tier offers it, because a name is more specific than a
    /// tier and a setting that quietly lost to another setting would be the same defect
    /// one level up.
    @Test("a named operator outside the profile is still offered")
    func namesBeatTheProfile() {
        let offered = Self.rules(
            Self.discover(Self.source, profile: .balanced, operators: ["bitand-to-bitor"]))
        #expect(offered == ["bitand-to-bitor"], "\(offered)")
    }

    @Test("says what the names left out")
    func namesSayWhatTheyLeftOut() {
        let discovery = Self.discover(Self.source, operators: ["lt-to-le"])
        #expect(discovery.skips.contains { $0.reason == .notSelected })
    }

    /// The tiers are inclusive in the order the settings file claims, whatever is in them.
    @Test("each tier contains the one below it")
    func tiersAreMonotone() {
        let balanced = Self.rules(Self.discover(Self.source, profile: .balanced))
        let strong = Self.rules(Self.discover(Self.source, profile: .strong))
        let all = Self.rules(Self.discover(Self.source, profile: .all))
        #expect(balanced.isSubset(of: strong), "\(balanced) vs \(strong)")
        #expect(strong.isSubset(of: all), "\(strong) vs \(all)")
    }
}
