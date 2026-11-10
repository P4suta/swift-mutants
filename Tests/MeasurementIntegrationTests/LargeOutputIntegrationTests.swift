// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutants
import Testing

@Suite("Complete results with large diagnostics", .serialized)
struct LargeOutputIntegrationTests {
    @Test("complete Swift Testing failures remain measurable", arguments: [false, true])
    func completeFailure(stderr: Bool) async throws {
        let package = try PackageFixture(
            tests: Self.tests(stderr: stderr), source: "public func finished() -> Bool { true }")
        defer { try? package.remove() }
        let report = try await MutationTesting.run(packageAt: package.root)
        #expect(report.results.map(\.outcome) == [.killed])
        #expect(report.score == 1)
    }

    @Test("a late crash after recorded failure remains an execution error")
    func lateCrash() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(
            path: "late-crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let exit = """
            atexit {
                try? Data("exited".utf8).write(to: URL(filePath: \(String(reflecting: marker.path))))
                fatalError("fixture crash after run completion")
            }
            """
        let package = try PackageFixture(
            tests: Self.tests(stderr: true, exit: exit),
            source: "public func finished() -> Bool { true }")
        defer { try? package.remove() }
        let report = try await MutationTesting.run(packageAt: package.root)
        #expect(report.results.map(\.outcome) == [.errored])
        #expect(report.score == nil)
        let explainsExit =
            report.results.first?.diagnostic?.hasPrefix(
                "SwiftPM reported an abnormal test process exit.") == true
        #expect(explainsExit)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    private static func tests(stderr: Bool, exit: String = "") -> String {
        """
        import Darwin
        import Foundation
        import Testing
        import Subject
        @Test func finishes() throws {
            if !finished() {
                let output = FileHandle.\(stderr ? "standardError" : "standardOutput")
                try output.write(contentsOf: Data(repeating: 120, count: 2 << 20))
                \(exit)
            }
            #expect(finished())
        }
        """
    }
}
