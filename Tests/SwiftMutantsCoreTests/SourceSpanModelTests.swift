// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsCore

@Suite("Source range model correspondence")
struct SourceSpanModelTests {
    @Test("source shifts match the checked signed-boundary fixture")
    func shifts() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appending(path: "Proofs/ranges.csv"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        try #require(lines.first == "start,end,distance,shiftedStart,shiftedEnd")
        var seen: Set<String> = []
        for line in lines.dropFirst() {
            let row = line.split(separator: ",", omittingEmptySubsequences: false)
            try #require(row.count == 5)
            let start = try #require(Int(row[0]))
            let end = try #require(Int(row[1]))
            let distance = try #require(Int(row[2]))
            let original = try #require(SourceSpan(start: start, end: end))
            let shifted = original.shifted(by: distance)
            if row[3] == "nil" {
                try #require(row[4] == "nil")
                try #require(shifted == nil)
            } else {
                let value = try #require(shifted)
                try #require(value.start == Int(row[3]))
                try #require(value.end == Int(row[4]))
            }
            seen.insert(row.prefix(3).joined(separator: ","))
        }
        #expect(lines.count == 190)
        #expect(seen.count == 189)
    }
}
