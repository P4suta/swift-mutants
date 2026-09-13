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
    // macOS 15 for Synchronization.Mutex, which is what lets the trace recorder be a
    // Sendable value with a cheap synchronous `record` rather than an actor whose every
    // call site would have to be async. Nothing is lost: Swift 6.3 means Xcode 26, which
    // does not run on macOS 14.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwiftMutantsCore", targets: ["SwiftMutantsCore"])
    ],
    dependencies: [
        // Foundation.Process has no structured-concurrency cancellation and deadlocks when
        // a child fills a pipe nobody is draining. A mutant deadline needs both, and a
        // teardown sequence besides, so the runner is built on this instead.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),

        // Parsing Swift. The major version is a hard toolchain boundary - 603 is Swift 6.3 -
        // so it is pinned to the range rather than left to float.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "603.0.2"..<"604.0.0"),

        // The command line. 1.8 is the first that requires Swift 6, which this does anyway.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(name: "SwiftMutantsCore", swiftSettings: strict),

        // Reading a configuration, strictly. Pure: it turns text into values and says
        // precisely where it stopped.
        .target(
            name: "SwiftMutantsConfig",
            dependencies: ["SwiftMutantsCore"],
            swiftSettings: strict
        ),

        // The account a run keeps of itself. Pure: it decides what an event *is* and how
        // it is written down, while a sink that touches a disk lives outside.
        .target(
            name: "SwiftMutantsTrace",
            dependencies: ["SwiftMutantsCore"],
            swiftSettings: strict
        ),

        // Finding what could be mutated, and what was deliberately passed over.
        .target(
            name: "SwiftMutantsDiscover",
            dependencies: [
                "SwiftMutantsCore",
                "SwiftMutantsConfig",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            swiftSettings: strict
        ),

        // The pipeline: what a run does, in the order it does it.
        .target(
            name: "SwiftMutantsEngine",
            dependencies: [
                "SwiftMutantsBuild", "SwiftMutantsConfig", "SwiftMutantsConsole",
                "SwiftMutantsCore", "SwiftMutantsDiscover", "SwiftMutantsInstrument",
                "SwiftMutantsRunner", "SwiftMutantsSnapshot", "SwiftMutantsTrace",
            ],
            swiftSettings: strict
        ),

        // The command tree, and nothing else.
        .target(
            name: "SwiftMutantsCLI",
            dependencies: [
                "SwiftMutantsEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strict
        ),

        // A thin main.
        .executableTarget(
            name: "swift-mutants",
            dependencies: ["SwiftMutantsCLI"],
            swiftSettings: strict
        ),

        // What a package holds, asked of whatever build system owns it.
        .target(
            name: "SwiftMutantsBuild",
            dependencies: ["SwiftMutantsCore", "SwiftMutantsRunner", "SwiftMutantsTrace"],
            swiftSettings: strict
        ),

        // Putting every compilable mutant into one tree, each dormant behind a guard.
        .target(
            name: "SwiftMutantsInstrument",
            dependencies: ["SwiftMutantsCore", "SwiftMutantsDiscover"],
            swiftSettings: strict
        ),

        // Running one mutant, watching what the tests say about it, and stopping the
        // moment the answer is known.
        .target(
            name: "SwiftMutantsExecute",
            dependencies: [
                "SwiftMutantsBuild", "SwiftMutantsCore", "SwiftMutantsInstrument",
                "SwiftMutantsRunner", "SwiftMutantsTrace",
            ],
            swiftSettings: strict
        ),

        // Finding out which mutants the compiler refuses, and saying so in its words.
        .target(
            name: "SwiftMutantsValidate",
            dependencies: [
                "SwiftMutantsCore", "SwiftMutantsInstrument", "SwiftMutantsRunner",
                "SwiftMutantsTrace",
            ],
            swiftSettings: strict
        ),

        // A disposable copy of somebody's package, and the manifest that says what is
        // in it. The first invariant: the tree a run was pointed at is never written to.
        .target(
            name: "SwiftMutantsSnapshot",
            dependencies: ["SwiftMutantsCore"],
            swiftSettings: strict
        ),

        // Where an account goes when it leaves memory: the recording a traced run
        // writes, and the bundle a failed run leaves behind.
        .target(
            name: "SwiftMutantsDiagnostics",
            dependencies: ["SwiftMutantsCore", "SwiftMutantsTrace"],
            swiftSettings: strict
        ),

        // The one place a subprocess is started, and therefore the one place one is
        // recorded. A call site can forget to record; it cannot forget to go through here.
        .target(
            name: "SwiftMutantsRunner",
            dependencies: [
                "SwiftMutantsCore",
                "SwiftMutantsTrace",
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            swiftSettings: strict
        ),

        // How a run reads. Pure: it turns values into lines, and something else puts
        // them on a terminal.
        .target(
            name: "SwiftMutantsConsole",
            dependencies: ["SwiftMutantsCore", "SwiftMutantsTrace"],
            swiftSettings: strict
        ),

        // A `swift` and an `xcodebuild` that answer from a rule table a test wrote.
        // It is a product rather than a function because the thing under test starts it as
        // a process: the only honest way to script a toolchain is to be one.
        .executableTarget(
            name: "swift-mutants-fake-toolchain",
            dependencies: ["SwiftMutantsTestKit"],
            swiftSettings: strict
        ),

        // Test support, and test support only. It lives under Sources/ because a
        // .testTarget cannot be a dependency of another .testTarget, not because it ships.
        // `TestKitIsolationGateTests` is what keeps production from importing it.
        .target(
            name: "SwiftMutantsTestKit",
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsCoreTests",
            dependencies: ["SwiftMutantsCore"],
            swiftSettings: strict
        ),

        .testTarget(
            name: "SwiftMutantsEngineTests",
            dependencies: ["SwiftMutantsEngine", "SwiftMutantsTestKit"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsBuildTests",
            dependencies: ["SwiftMutantsBuild", "SwiftMutantsTestKit"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "InstrumentIntegrationTests",
            dependencies: ["SwiftMutantsInstrument", "SwiftMutantsTestKit"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsInstrumentTests",
            dependencies: ["SwiftMutantsInstrument"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "ExecuteIntegrationTests",
            dependencies: [
                "SwiftMutantsExecute", "SwiftMutantsBuild", "SwiftMutantsTestKit",
                "SwiftMutantsTrace",
            ],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsExecuteTests",
            dependencies: ["SwiftMutantsExecute", "SwiftMutantsBuild", "SwiftMutantsTrace"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsValidateTests",
            dependencies: ["SwiftMutantsValidate", "SwiftMutantsDiscover"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "ValidateIntegrationTests",
            dependencies: [
                "SwiftMutantsValidate", "SwiftMutantsDiscover", "SwiftMutantsInstrument",
                "SwiftMutantsTestKit",
            ],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsDiscoverTests",
            dependencies: ["SwiftMutantsDiscover"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsSnapshotTests",
            dependencies: ["SwiftMutantsSnapshot"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsDiagnosticsTests",
            dependencies: ["SwiftMutantsDiagnostics"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "FakeToolchainTests",
            dependencies: ["SwiftMutantsTestKit", "SwiftMutantsRunner"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsRunnerTests",
            dependencies: ["SwiftMutantsRunner"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsConsoleTests",
            dependencies: ["SwiftMutantsConsole"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsConfigTests",
            dependencies: ["SwiftMutantsConfig"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SwiftMutantsTraceTests",
            dependencies: ["SwiftMutantsTrace"],
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
