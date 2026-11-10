// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsRunner

@Suite("Streaming output matches")
struct OutputMatchingTests {
    @Test("matches survive every chunk boundary and overlapping needles")
    func chunkBoundaries() {
        let bytes: [UInt8] =
            [0xFF] + Array("noise_ababa_runtime-token_unicode-\u{00E9}".utf8) + [0xFE]
        let needles = ["aba", "ababa", "runtime-token", "unicode-\u{00E9}", "absent", "", "aba"]
        for split in 0...bytes.count {
            var matcher = OutputMatcher(needles)
            matcher.append(Array(bytes[..<split]))
            matcher.append([])
            matcher.append(Array(bytes[split...]))
            #expect(matcher.found == ["aba", "ababa", "runtime-token", "unicode-\u{00E9}"])
        }
        var matcher = OutputMatcher(needles)
        for byte in bytes { matcher.append([byte]) }
        #expect(matcher.found == ["aba", "ababa", "runtime-token", "unicode-\u{00E9}"])
    }

    @Test("memory depends on needles rather than the amount drained")
    func boundedMemory() {
        var matcher = OutputMatcher(["runtime-token", "absent"])
        for _ in 0..<1_024 {
            matcher.append(Array(repeating: 0x78, count: 1_024))
            #expect(matcher.suffix.count <= "runtime-token".utf8.count - 1)
        }
        matcher.append(Array("runtime-token".utf8))
        #expect(matcher.found == ["runtime-token"])
    }

    @Test("stdout matches remain available beyond the diagnostic prefix")
    func afterPrefix() async {
        let result = await Runner(recorder: TraceRecorder(), outputLimit: 4).run(
            RunnerTests.shell("printf 'noise-runtime-token'; printf 'stderr-token' >&2"),
            matchingOutput: ["runtime-token", "absent", "stderr-token"]
        )
        #expect(result.exitCode == 0)
        #expect(result.startFailure == nil)
        #expect(result.standardOutputWasCut)
        #expect(result.standardOutput.count == 4)
        #expect(result.standardError.count == 4)
        #expect(result.matchedOutput == ["runtime-token"])
    }
}
