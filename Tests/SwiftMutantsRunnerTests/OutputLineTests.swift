// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsRunner

@Suite("Streaming diagnostic lines")
struct OutputLineTests {
    private static let crash = OutputLinePattern(
        prefix: "error: Process '", containing: "exited with unexpected signal code")

    @Test("line conditions survive every chunk boundary")
    func boundaries() {
        let input = Array("noise\nerror: Process '/tool' exited with unexpected signal code 5".utf8)
        for split in 0...input.count {
            var lines = OutputLines([Self.crash])
            lines.append(Array(input[..<split]))
            lines.append([])
            lines.append(Array(input[split...]))
            #expect(lines.found == [Self.crash])
        }
        var lines = OutputLines([Self.crash])
        for byte in input { lines.append([byte]) }
        #expect(lines.found == [Self.crash])
    }

    @Test("quoted, indented, and split-line text doesn't impersonate a diagnostic")
    func unrelatedText() {
        let inputs = [
            "argument: \"error: Process '/tool' exited with unexpected signal code 5\"",
            "    error: Process '/tool' exited with unexpected signal code 5\n",
            "error: Process '/tool'\nexited with unexpected signal code 5\n",
            "error: Process '/tool' exited normally\n",
        ]
        for input in inputs {
            var lines = OutputLines([Self.crash])
            for byte in input.utf8 { lines.append([byte]) }
            #expect(lines.found.isEmpty)
        }
    }

    @Test("prefix-only and containing-only patterns keep their own conditions")
    func conditions() {
        let prefix = OutputLinePattern(prefix: "error: Exited with signal")
        let containing = OutputLinePattern(containing: "Test Case '-[")
        var lines = OutputLines([prefix, containing, Self.crash, OutputLinePattern()])
        lines.append(
            Array("error: Exited with signal 5\r\nworker: Test Case '-[Suite test]' passed".utf8))
        #expect(lines.found == [prefix, containing])
    }

    @Test("abnormal lines remain visible beyond both diagnostic prefixes")
    func afterPrefix() async {
        let prefix = OutputLinePattern(prefix: "error: Exited with signal")
        let result = await Runner(recorder: TraceRecorder(), outputLimit: 4).run(
            RunnerTests.shell(
                "printf 'noise\\nerror: Exited with signal 5'; printf 'noise\\nerror: Process '\"'\"'/tool'\"'\"' exited with unexpected signal code 5' >&2"
            ),
            matchingLines: [prefix, Self.crash]
        )
        #expect(result.exitCode == 0)
        #expect(result.standardOutputWasCut)
        #expect(result.standardErrorWasCut)
        #expect(result.matchedLines == [prefix, Self.crash])
    }
}
