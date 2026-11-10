// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

struct OutputMatcher: Sendable {
    private var pending: [String: Data]
    private let overlap: Int
    private(set) var found: Set<String> = []
    private(set) var suffix: [UInt8] = []

    init(_ needles: [String]) {
        pending = Dictionary(
            uniqueKeysWithValues: Set(needles).filter { !$0.isEmpty }.map {
                ($0, Data($0.utf8))
            })
        overlap = max(0, (pending.values.map(\.count).max() ?? 0) - 1)
    }

    mutating func append(_ bytes: [UInt8]) {
        guard !pending.isEmpty else { return }
        let window = Data(suffix + bytes)
        let matches = pending.filter { window.range(of: $0.value) != nil }.keys
        for match in matches {
            found.insert(match)
            pending.removeValue(forKey: match)
        }
        suffix = pending.isEmpty ? [] : Array(window.suffix(overlap))
    }
}
