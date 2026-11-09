// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsRunner
import SwiftMutantsTestKit
import SwiftMutantsTrace
import Testing

@Suite("Public library consumer")
struct LibraryConsumerTests {
    static var manifest: String {
        """
        // swift-tools-version: 6.3
        import PackageDescription

        let package = Package(
            name: "Consumer",
            platforms: [.macOS(.v15)],
            dependencies: [.package(path: \(String(reflecting: RepositoryGate.root.path)))],
            targets: [
                .testTarget(
                    name: "ConsumerTests",
                    dependencies: [.product(name: "SwiftMutants", package: "swift-mutants")]
                ),
            ]
        )
        """
    }

    static let source = #"""
        import Foundation
        import SwiftMutants
        import Testing

        @Test func publicSourceMutation() throws {
            let source = "func compare(_ a: Int, _ b: Int) -> Bool { a < b }"
            let mutations = try Mutation.discover(in: source, at: "Sources/Subject.swift")
            let mutation = try #require(mutations.first { $0.rule == "lt-to-le" })
            #expect(mutation.path == "Sources/Subject.swift")
            #expect(mutation.id.count == 64)
            #expect(
                try mutation.applying(to: source)
                    == "func compare(_ a: Int, _ b: Int) -> Bool { a <= b }")
            #expect(throws: MutationError.sourceChanged(path: mutation.path)) {
                try mutation.applying(to: source + " ")
            }
            print("PUBLIC_LIBRARY_CONSUMER_PASSED")
        }


        @Test func publicPackageMeasurement() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "swift-mutants-external-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            func write(_ path: String, _ text: String) throws {
                let file = root.appending(path: path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            try write("Package.swift", """
                // swift-tools-version: 6.3
                import PackageDescription
                let package = Package(name: "Subject", targets: [
                    .target(name: "Subject"),
                    .testTarget(name: "SubjectTests", dependencies: ["Subject"]),
                ])
                """)
            try write("Sources/Subject/Subject.swift", """
                public func add(_ a: Int, _ b: Int) -> Int { a + b }
                public func scale(_ a: Int, _ b: Int) -> Int { a * b }
                """)
            try write("Tests/SubjectTests/SubjectTests.swift", """
                import Testing
                import Subject
                @Test func adds() { #expect(add(2, 3) == 5) }
                """)
            let candidates = try await MutationTesting.list(packageAt: root)
            let report = try await MutationTesting.run(packageAt: root)
            #expect(Set(candidates.map(\.id)) == Set(report.results.map(\.mutation.id)))
            #expect(report.summary.killed == 1)
            #expect(report.summary.survived == 1)
            #expect(report.score == 0.5)
            print("PUBLIC_MEASUREMENT_CONSUMER_PASSED")
        }
        """#

    @Test("a separate package discovers, edits, and measures with the public product")
    func usesPublicProduct() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-consumer-\(UUID().uuidString)")
        let tests = directory.appending(path: "Tests/ConsumerTests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Self.manifest.write(
            to: directory.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try Self.source.write(
            to: tests.appending(path: "ConsumerTests.swift"),
            atomically: true,
            encoding: .utf8
        )

        let ambient = ProcessInfo.processInfo.environment
        let environment = ["HOME", "PATH", "DEVELOPER_DIR", "TMPDIR", "SDKROOT"]
            .reduce(into: [String: String]()) { $0[$1] = ambient[$1] }
        let outcome = await Runner(recorder: TraceRecorder()).run(
            ProcessSpec(
                kind: .testFixture,
                executable: "/usr/bin/env",
                arguments: [
                    "swift", "test", "--package-path", directory.path, "--quiet",
                    "-Xswiftc", "-warnings-as-errors",
                ],
                directory: directory.path,
                environment: environment,
                timeout: .seconds(180)
            )
        )
        try #require(
            outcome.exitCode == 0,
            "\(outcome.standardOutputText)\n\(outcome.standardErrorText)"
        )
        #expect(outcome.standardOutputText.contains("PUBLIC_LIBRARY_CONSUMER_PASSED"))
        #expect(outcome.standardOutputText.contains("PUBLIC_MEASUREMENT_CONSUMER_PASSED"))
    }
}
