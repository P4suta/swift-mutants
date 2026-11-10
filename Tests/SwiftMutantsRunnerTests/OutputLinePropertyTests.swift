// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsRunner

@Suite("Streaming line correspondence")
struct OutputLinePropertyTests {
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
