// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

@Suite("Source range properties")
struct SourceSpanPropertyTests {
    @Test("interval operations agree with independent sets of bytes and boundaries")
    func intervals() throws {
        let spans = try (0...8).flatMap { start in
            try (start...8).map { end in try #require(SourceSpan(start: start, end: end)) }
        }
        for left in spans {
            let bytes = Set(left.start..<left.end)
            let boundaries = Set(left.start...left.end)
            try #require(left.isEmpty == bytes.isEmpty)
            try #require(left.length == bytes.count)
            for offset in -1...9 {
                try #require(left.contains(offset: offset) == bytes.contains(offset))
            }
            for right in spans {
                let shared = bytes.intersection(Set(right.start..<right.end))
                try #require(left.overlaps(right) == !shared.isEmpty)
                try #require(
                    left.contains(right) == boundaries.isSuperset(of: Set(right.start...right.end)))
                try #require(!(left < right && right < left))
                try #require(left < right || left == right || right < left)
                if left < right {
                    for last in spans where right < last { try #require(left < last) }
                }
            }
        }
    }

    @Test("source shifts agree with a wider integer oracle at representable boundaries")
    func shifts() throws {
        let offsets = [0, 1, 2, 7, Int.max - 1, Int.max]
        let distances = [Int.min, Int.min + 1, -7, -1, 0, 1, 7, Int.max - 1, Int.max]
        for start in offsets {
            for end in offsets where end >= start {
                let span = try #require(SourceSpan(start: start, end: end))
                for distance in distances {
                    let first = Int128(start) + Int128(distance)
                    let last = Int128(end) + Int128(distance)
                    let shifted = span.shifted(by: distance)
                    if first >= 0, last <= Int128(Int.max) {
                        let value = try #require(shifted)
                        try #require(Int128(value.start) == first)
                        try #require(Int128(value.end) == last)
                    } else {
                        try #require(shifted == nil)
                    }
                }
            }
        }
    }
}
