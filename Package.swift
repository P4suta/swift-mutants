// swift-tools-version: 6.3
// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import PackageDescription

// Upcoming features that Swift 6 language mode does NOT already enable.
//
// Enabling a feature that the language mode already implies emits "upcoming feature 'X' is already enabled as of Swift version 6", and CI builds with -warnings-as-errors, so a redundant entry here fails the build.
// The list is derived from `swiftc -print-supported-features` and held in place by `UpcomingFeatureLedgerTests`, which fails when the toolchain grows a feature this package has not decided about.
let upcomingFeatures: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

// -warnings-as-errors deliberately lives in the build invocation (`mise run check`, CI) rather than here: `unsafeFlags` would make this package unusable as a versioned dependency of anything else.
let strict: [SwiftSetting] =
    [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
    ] + upcomingFeatures

let package = Package(
    name: "swift-mutants",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "swift-mutants", targets: ["swift-mutants"]),
        .library(name: "SwiftMutants", targets: ["SwiftMutants"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "603.0.2"..<"605.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "SwiftMutants",
            dependencies: [
                "SwiftMutantsCore", "SwiftMutantsDiscover", "SwiftMutantsInstrument",
                "SwiftMutantsBuild", "SwiftMutantsRunner", "SwiftMutantsSnapshot",
                "SwiftMutantsTrace",
            ],
            swiftSettings: strict
        ),
        .target(name: "SwiftMutantsCore", swiftSettings: strict),
        .target(
            name: "SwiftMutantsDiscover",
            dependencies: [
                "SwiftMutantsCore",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            swiftSettings: strict
        ),
        .target(
            name: "SwiftMutantsInstrument",
            dependencies: ["SwiftMutantsCore", "SwiftMutantsDiscover"],
            swiftSettings: strict
        ),
        .target(
            name: "SwiftMutantsBuild",
            dependencies: ["SwiftMutantsCore", "SwiftMutantsRunner"],
            swiftSettings: strict
        ),
        .target(
            name: "SwiftMutantsSnapshot",
            dependencies: ["SwiftMutantsCore"],
            swiftSettings: strict
        ),
        .target(
            name: "SwiftMutantsTrace",
            dependencies: ["SwiftMutantsCore"],
            swiftSettings: strict
        ),
        .target(
            name: "SwiftMutantsRunner",
            dependencies: [
                "SwiftMutantsCore", "SwiftMutantsTrace",
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            swiftSettings: strict
        ),
        .target(
            name: "SwiftMutantsCLI",
            dependencies: [
                "SwiftMutants", "SwiftMutantsCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "swift-mutants",
            dependencies: [
                "SwiftMutantsCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strict
        ),
        .target(name: "SwiftMutantsTestKit", swiftSettings: strict),
        .testTarget(
            name: "SwiftMutantsTests",
            dependencies: [
                "SwiftMutants", "SwiftMutantsCore", "SwiftMutantsDiscover",
                "SwiftMutantsInstrument", "SwiftMutantsSnapshot",
            ],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsCoreTests", dependencies: ["SwiftMutantsCore"], swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsDiscoverTests",
            dependencies: ["SwiftMutantsDiscover", "SwiftMutantsCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsInstrumentTests",
            dependencies: ["SwiftMutantsInstrument", "SwiftMutantsCore", "SwiftMutantsDiscover"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsSnapshotTests",
            dependencies: ["SwiftMutantsSnapshot", "SwiftMutantsCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsRunnerTests",
            dependencies: ["SwiftMutantsRunner", "SwiftMutantsTrace"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsTraceTests",
            dependencies: ["SwiftMutantsTrace", "SwiftMutantsCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsCLITests",
            dependencies: ["SwiftMutantsCLI", "SwiftMutants"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "RepositoryGateTests",
            dependencies: ["SwiftMutantsTestKit", "SwiftMutantsRunner", "SwiftMutantsTrace"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "CompilerGateIntegrationTests",
            dependencies: [
                "SwiftMutantsTestKit", "SwiftMutantsRunner", "SwiftMutantsTrace",
                "SwiftMutantsCore", "SwiftMutantsDiscover", "SwiftMutantsInstrument",
            ],
            swiftSettings: strict
        ),
        .testTarget(
            name: "InstrumentIntegrationTests",
            dependencies: [
                "SwiftMutantsTestKit", "SwiftMutantsCore", "SwiftMutantsDiscover",
                "SwiftMutantsInstrument",
            ],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MeasurementIntegrationTests",
            dependencies: [
                "SwiftMutants", "SwiftMutantsCLI", "SwiftMutantsTestKit", "SwiftMutantsRunner",
                "SwiftMutantsTrace",
            ],
            swiftSettings: strict
        ),
    ]
)
