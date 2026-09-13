// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTestKit
import Testing

/// Keeps `Package.swift`'s upcoming-feature list honest against the toolchain in use.
///
/// Two failure modes sit on either side of this ledger and both are silent without it.
/// Enable a feature Swift 6 language mode already implies and the compiler answers
/// "upcoming feature 'X' is already enabled as of Swift version 6" - a warning, which
/// under the `-warnings-as-errors` every gated build carries is a broken build. Fail to
/// enable one it does *not* imply and the package quietly compiles under weaker rules
/// than it claims to.
///
/// The split below was measured, not guessed: each of the toolchain's twenty-one upcoming
/// features was compiled on its own against Swift 6 mode and sorted by whether the
/// compiler called it redundant.
@Suite("Upcoming feature ledger")
struct UpcomingFeatureLedgerTests {

    /// Features Swift 6 language mode already enables, so naming them would warn.
    static let redundantUnderSwift6: Set<String> = [
        "BareSlashRegexLiterals",
        "ConciseMagicFile",
        "DeprecateApplicationMain",
        "DisableOutwardActorInference",
        "DynamicActorIsolation",
        "ForwardTrailingClosures",
        "GlobalActorIsolatedTypesUsability",
        "GlobalConcurrency",
        "ImplicitOpenExistentials",
        "ImportObjcForwardDeclarations",
        "InferSendableFromCaptures",
        "IsolatedDefaultValues",
        "NonfrozenEnumExhaustivity",
        "RegionBasedIsolation",
    ]

    /// Features this package declines, each for a reason written down here.
    ///
    /// `StrictConcurrency` is the Swift 5 migration switch for the checking that
    /// `swiftLanguageMode(.v6)` already turns on in full. The compiler does not call it
    /// redundant, so it would compile - but naming it would suggest the language mode
    /// were not already doing the work, and a setting that changes nothing is a setting
    /// somebody later has to investigate.
    static let deliberatelyDeclined: Set<String> = ["StrictConcurrency"]

    @Test("every upcoming feature the toolchain offers has been decided about")
    func ledgerCoversTheToolchain() throws {
        let offered = try Self.upcomingFeaturesOfferedByToolchain()
        let declared = try Self.featuresEnabledByPackageManifest()
        let accountedFor = declared.union(Self.redundantUnderSwift6).union(
            Self.deliberatelyDeclined)
        let undecided = offered.subtracting(accountedFor).sorted()

        #expect(
            undecided.isEmpty,
            """
            The toolchain offers upcoming features this package has not decided about. \
            Compile each one on its own under -swift-version 6 and then either enable it \
            in Package.swift, or record it in `redundantUnderSwift6` if the compiler says \
            it is already on, or in `deliberatelyDeclined` with the reason.
            Undecided: \(undecided.joined(separator: ", "))
            """
        )
    }

    @Test("nothing the manifest enables is already on")
    func declaredFeaturesAreNotRedundant() throws {
        let declared = try Self.featuresEnabledByPackageManifest()
        let redundant = declared.intersection(Self.redundantUnderSwift6).sorted()
        #expect(
            redundant.isEmpty,
            """
            Package.swift enables features Swift 6 language mode already implies. Each one \
            emits "already enabled as of Swift version 6", which -warnings-as-errors turns \
            into a failed build.
            Remove: \(redundant.joined(separator: ", "))
            """
        )
    }

    @Test("the ledger claims nothing the toolchain does not offer")
    func ledgerHasNoStaleEntries() throws {
        let offered = try Self.upcomingFeaturesOfferedByToolchain()
        let claimed = Self.redundantUnderSwift6.union(Self.deliberatelyDeclined)
        let stale = claimed.subtracting(offered).sorted()
        #expect(
            stale.isEmpty,
            """
            The ledger names features this toolchain does not offer. They were probably \
            promoted into the language, so the entries are now noise.
            Stale: \(stale.joined(separator: ", "))
            """
        )
    }
}

extension UpcomingFeatureLedgerTests {
    private static func upcomingFeaturesOfferedByToolchain() throws -> Set<String> {
        let json = try ToolchainGate.run("swiftc", ["-print-supported-features"])
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let features = root["features"] as? [String: Any],
            let upcoming = features["upcoming"] as? [[String: Any]]
        else {
            throw ToolchainGate.Failure(
                "swiftc -print-supported-features did not answer with a features.upcoming array")
        }
        return Set(upcoming.compactMap { $0["name"] as? String })
    }

    private static func featuresEnabledByPackageManifest() throws -> Set<String> {
        let manifest = try String(
            contentsOf: RepositoryGate.root.appending(path: "Package.swift"),
            encoding: .utf8
        )
        let call = /\.enableUpcomingFeature\("([A-Za-z0-9_]+)"\)/
        return Set(manifest.matches(of: call).map { String($0.1) })
    }
}
