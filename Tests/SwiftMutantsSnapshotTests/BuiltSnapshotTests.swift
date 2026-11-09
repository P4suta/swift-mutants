// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsSnapshot
import Testing

@Suite("Built snapshot inputs")
struct BuiltSnapshotTests {
    @Test("records resolved build inputs before checking test side effects")
    func recordsBuildInputs() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swift-mutants-built-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "original")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try "let value = true".write(
            to: original.appending(path: "Subject.swift"),
            atomically: true,
            encoding: .utf8
        )
        let snapshot = try Snapshot.create(of: original, at: directory.appending(path: "copy"))
        let resolved = snapshot.root.appending(path: "Package.resolved")
        try "resolved by build".write(to: resolved, atomically: true, encoding: .utf8)
        let built = try snapshot.recordingCurrentFiles()
        #expect(try built.drift().isEmpty)
        try "changed by tests".write(to: resolved, atomically: true, encoding: .utf8)
        #expect(try built.drift().map(\.rendered) == ["Package.resolved"])
        #expect(
            !FileManager.default.fileExists(
                atPath: original.appending(path: "Package.resolved").path
            )
        )
    }
}
