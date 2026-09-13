// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import PackageDescription

// Upcoming features that Swift 6 language mode does NOT already enable.
//
// Enabling a feature that the language mode already implies emits
// "upcoming feature 'X' is already enabled as of Swift version 6", and CI builds
// with -warnings-as-errors, so a redundant entry here fails the build. The list is
// derived from `swiftc -print-supported-features` and held in place by
// `UpcomingFeatureLedgerTests`, which fails when the toolchain grows a feature this
// package has not decided about.
let upcomingFeatures: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

// -warnings-as-errors deliberately lives in the build invocation (`mise run check`,
// CI) rather than here: `unsafeFlags` would make this package unusable as a
// versioned dependency of anything else.
let strict: [SwiftSetting] =
    [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
    ] + upcomingFeatures

let package = Package(
    name: "swift-mutants",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftMutantsCore", targets: ["SwiftMutantsCore"])
    ],
    targets: [
        .target(name: "SwiftMutantsCore", swiftSettings: strict),

        // Test support, and test support only. It lives under Sources/ because a
        // .testTarget cannot be a dependency of another .testTarget, not because it ships.
        // `TestKitIsolationGateTests` is what keeps production from importing it.
        .target(name: "SwiftMutantsTestKit", swiftSettings: strict),
        .testTarget(
            name: "SwiftMutantsCoreTests",
            dependencies: ["SwiftMutantsCore"],
            swiftSettings: strict
        ),

        // Gates over the repository itself. They read files but drive no toolchain, so
        // they belong to the unit tier and run in the inner loop.
        .testTarget(
            name: "RepositoryGateTests",
            dependencies: ["SwiftMutantsTestKit"],
            swiftSettings: strict
        ),

        // Gates that have to ask the real compiler a question. Integration tier: slower,
        // and excluded from `mise run test:unit`.
        .testTarget(
            name: "CompilerGateIntegrationTests",
            dependencies: ["SwiftMutantsTestKit"],
            swiftSettings: strict
        ),
    ]
)
