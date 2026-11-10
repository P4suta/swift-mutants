// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsRunner

@Suite("Streaming line correspondence")
struct OutputLinePropertyTests {
    @Test("bounded streams match complete LF-separated lines at every split")
    func boundedStreams() {
        let symbols = ["a", "b"]
        let words = [""] + symbols + symbols.flatMap { prefix in symbols.map { prefix + $0 } }
        let patterns = words.flatMap { prefix in
            words.map { OutputLinePattern(prefix: prefix, containing: $0) }
        }
        let alphabet: [UInt8] = [0x61, 0x62, 0x0A]
        var inputs: [[UInt8]] = [[]]
        var level: [[UInt8]] = [[]]
        for _ in 0..<4 {
            level = level.flatMap { prefix in alphabet.map { prefix + [$0] } }
            inputs.append(contentsOf: level)
        }
        for bytes in inputs {
            let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            let expected = Set(
                patterns.filter { pattern in
                    guard !pattern.prefix.isEmpty || pattern.containing != nil else { return false }
                    return lines.contains { line in
                        line.hasPrefix(pattern.prefix)
                            && (pattern.containing.map(line.contains) ?? true)
                    }
                })
            for split in 0...bytes.count {
                var matcher = OutputLines(patterns)
                matcher.append(Array(bytes[..<split]))
                matcher.append(Array(bytes[split...]))
                #expect(matcher.found == expected, "bytes=\(bytes), split=\(split)")
            }
        }
    }

    @Test("streaming matches agree with complete line predicates at every split")
    func completeLines() {
        let patterns = [
            OutputLinePattern(), OutputLinePattern(containing: ""),
            OutputLinePattern(prefix: "error:"),
            OutputLinePattern(prefix: "error:", containing: ""),
            OutputLinePattern(prefix: "error:", containing: "signal"),
            OutputLinePattern(containing: "signal"),
            OutputLinePattern(prefix: "\u{00E9}", containing: "\u{1F600}"),
        ]
        let inputs = [
            "", "error:", "error: signal", "noise\nerror: signal\r\n",
            "error:\nsignal", "noise\nerror: normal\nerror: signal",
            "noise error: signal", "\u{00E9}\u{1F600}", "error: \u{1F600} signal",
        ]
        for input in inputs {
            let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
            let expected = Set(
                patterns.filter { pattern in
                    guard !pattern.prefix.isEmpty || !(pattern.containing ?? "").isEmpty else {
                        return false
                    }
                    return lines.contains { line in
                        line.hasPrefix(pattern.prefix)
                            && (pattern.containing.map { String(line).contains($0) } ?? true)
                    }
                })
            let bytes = Array(input.utf8)
            for split in 0...bytes.count {
                var matcher = OutputLines(patterns)
                matcher.append(Array(bytes[..<split]))
                matcher.append(Array(bytes[split...]))
                #expect(matcher.found == expected, "input=\(input), split=\(split)")
            }
        }
    }
}
