// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTrace

@testable import SwiftMutants

struct TestInvocationFixture {
    let root: URL
    let session: MeasurementSession
    let recorder = TraceRecorder()

    var executionLabels: [String] {
        recorder.retainedEvents().compactMap { event in
            guard case .exec(let execution) = event.kind else { return nil }
            return execution.label
        }
    }

    static let empty = "<testsuites tests='0'/>"
    static let outputLimit = 4_096
    static let passing =
        "<testsuite tests='1'><testcase classname='Suite' name='test'/></testsuite>"
    static let failing =
        "<testsuite tests='1' failures='1'><testcase name='test'><failure/></testcase></testsuite>"

    init(
        testing: String? = Self.passing,
        xctest: String? = Self.empty,
        status: Int = 0,
        output: String = "",
        errors: String = "",
        activation: String = "",
        delay: Bool = false,
        options: RunOptions = RunOptions()
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "invocation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.3\n".write(
            to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        let executable = root.appending(path: "toolchain")
        let script = """
            #!/bin/sh
            set -eu
            test "${SWIFT_MUTANTS_ACTIVE-}" = \(Self.quote(activation)) || exit 3
            printf '%s\\n' "$@" > \(Self.quote(root.appending(path: "arguments").path))
            while [ "$#" -gt 0 ]; do
                if [ "$1" = --xunit-output ]; then shift; report=$1; fi
                shift
            done
            \(delay ? "/bin/sleep 30" : ":")
            \(Self.write(xctest, to: "\"$report\""))
            \(Self.write(testing, to: "\"${report%.xml}-swift-testing.xml\""))
            printf '%s' \(Self.quote(output))
            printf '%s' \(Self.quote(errors)) >&2
            exit \(status)
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        session = try MeasurementSession(
            package: root,
            options: options,
            progress: { _ in },
            executable: executable.path,
            outputLimit: Self.outputLimit,
            recorder: recorder)
    }

    func product(_ name: String = "Fixture") -> TestProduct {
        TestProduct(name: name, binary: root.appending(path: "toolchain"), directory: root)
    }

    func clean() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try session.clean()
    }

    private static func write(_ text: String?, to path: String) -> String {
        text.map { "printf '%s' \(quote($0)) > \(path)" } ?? ":"
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
