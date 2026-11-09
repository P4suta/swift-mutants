// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

package struct OutputLinePattern: Sendable, Hashable {
    package let prefix: String
    package let containing: String?

    package init(prefix: String = "", containing: String? = nil) {
        self.prefix = prefix
        self.containing = containing
    }
}

struct OutputLines: Sendable {
    private var pending: [OutputLinePattern: OutputLine]
    private(set) var found: Set<OutputLinePattern> = []

    init(_ patterns: [OutputLinePattern]) {
        pending = Dictionary(
            uniqueKeysWithValues: Set(patterns).filter {
                !$0.prefix.isEmpty || !($0.containing ?? "").isEmpty
            }.map { ($0, OutputLine($0)) })
    }

    mutating func append(_ bytes: [UInt8]) {
        for pattern in Array(pending.keys) {
            guard var line = pending[pattern] else { continue }
            line.append(bytes)
            if line.found {
                found.insert(pattern)
                pending.removeValue(forKey: pattern)
            } else {
                pending[pattern] = line
            }
        }
    }
}

private struct OutputLine: Sendable {
    let pattern: OutputLinePattern
    let prefix: [UInt8]
    var observed: [UInt8] = []
    var eligible: Bool?
    var contains: OutputMatcher
    var found = false

    init(_ pattern: OutputLinePattern) {
        self.pattern = pattern
        prefix = Array(pattern.prefix.utf8)
        eligible = pattern.prefix.isEmpty ? true : nil
        contains = OutputMatcher(pattern.containing.map { [$0] } ?? [])
    }

    mutating func append(_ bytes: [UInt8]) {
        var start = bytes.startIndex
        for end in bytes.indices where bytes[end] == 0x0A {
            consume(bytes[start..<end])
            if found { return }
            observed = []
            eligible = prefix.isEmpty ? true : nil
            contains = OutputMatcher(pattern.containing.map { [$0] } ?? [])
            start = end + 1
        }
        consume(bytes[start...])
    }

    private mutating func consume(_ bytes: ArraySlice<UInt8>) {
        guard eligible != false else { return }
        if eligible == nil {
            observed.append(contentsOf: bytes.prefix(prefix.count - observed.count))
            guard prefix.starts(with: observed) else { eligible = false; return }
            if observed.count == prefix.count { eligible = true }
        }
        contains.append(Array(bytes))
        found =
            eligible == true
            && (pattern.containing == nil || !contains.found.isEmpty)
    }
}
