// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import SwiftMutants

@Suite("Measurement adapter contracts", .serialized)
struct AdapterIntegrationTests {
    @Test("individual edits agree with instrumentation")
    func individualParity() async throws {
        let package = try PackageFixture(
            tests: PackageFixture.testing + "\n" + PackageFixture.xctest
        )
        defer { try? package.remove() }
        let instrumented = try await MutationTesting.run(packageAt: package.root)
        let session = try MeasurementSession(
            package: package.root,
            options: RunOptions(),
            progress: { _ in }
        )
        defer { try? session.clean() }
        let individual = try await session.measure(instrumenting: false)
        #expect(individual.results.map(\.mutation.id) == instrumented.results.map(\.mutation.id))
        #expect(individual.results.map(\.outcome) == instrumented.results.map(\.outcome))
        #expect(individual.score == instrumented.score)
    }

    @Test("source selection and unsupported boundaries fail explicitly")
    func packageBoundaries() async throws {
        let package = try PackageFixture(tests: PackageFixture.testing)
        defer { try? package.remove() }
        #expect(
            try await MutationTesting.list(packageAt: package.root, exclude: ["Sources/**"]).isEmpty
        )
        do {
            _ = try await MutationTesting.run(
                packageAt: package.root,
                options: RunOptions(mutantIDs: ["unknown"])
            )
            Issue.record("An unknown identity was accepted")
        } catch let error as MutationTestingError { #expect(error.stage == .input) }
        try FileManager.default.createSymbolicLink(
            at: package.root.appending(path: "fixture"),
            withDestinationURL: package.root.deletingLastPathComponent()
        )
        do {
            _ = try await MutationTesting.list(packageAt: package.root)
            Issue.record("An external fixture link was accepted")
        } catch let error as MutationTestingError { #expect(error.stage == .snapshot) }
        try FileManager.default.removeItem(at: package.root.appending(path: "fixture"))
        let manifest = """
            // swift-tools-version: 6.3
            import PackageDescription
            let package = Package(name: "Subject", dependencies: [.package(path: "../External")])
            """
        try package.write("Package.swift", manifest)
        do {
            _ = try await MutationTesting.list(packageAt: package.root)
            Issue.record("An external local dependency was accepted")
        } catch let error as MutationTestingError {
            #expect(error.stage == .discovery)
        }
    }

    @Test("corrupt result XML stops a real package baseline")
    func corruptXML() async throws {
        let package = try PackageFixture(tests: PackageFixture.testing)
        defer { try? package.remove() }
        let wrapper = package.root.appending(path: "toolchain")
        let script = """
            #!/bin/sh
            shift
            /usr/bin/swift "$@"
            status=$?
            if [ "$1" = test ]; then
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = --xunit-output ]; then
                        shift
                        printf '<broken>' > "$1"
                        break
                    fi
                    shift
                done
            fi
            exit "$status"
            """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wrapper.path
        )
        let session = try MeasurementSession(
            package: package.root,
            options: RunOptions(),
            progress: { _ in },
            executable: wrapper.path
        )
        defer { try? session.clean() }
        do {
            _ = try await session.measure()
            Issue.record("Corrupt XML was accepted")
        } catch let error as MutationTestingError {
            #expect(error.stage == .baseline)
            #expect(error.diagnostic.contains("invalid test results"))
        }
    }

    @Test("inactive baselines stop before measuring source-dependent tests")
    func inactiveBaseline() async throws {
        let tests = """
            import Foundation
            import Testing
            @Test func originalSource() throws {
                let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let text = try String(contentsOf: root.appending(path: "Sources/Subject/Subject.swift"), encoding: .utf8)
                #expect(!text.contains("swift-mutants runtime."))
            }
            """
        let package = try PackageFixture(tests: tests)
        defer { try? package.remove() }
        let measured = Mutex(0)
        do {
            _ = try await MutationTesting.run(packageAt: package.root) { event in
                if case .measured = event { measured.withLock { $0 += 1 } }
            }
            Issue.record("A changed inactive baseline was accepted")
        } catch let error as MutationTestingError {
            #expect(error.stage == .baseline)
        }
        #expect(measured.withLock { $0 } == 0)
    }
}
