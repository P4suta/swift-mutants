// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// The comments a file uses to ask for less.
///
/// A comment rather than an attribute, deliberately. An attribute would mean the project
/// taking a dependency on this tool in order to say "do not mutate this line", and a
/// testing tool has no business appearing in the dependency graph of a shipped binary.
///
/// The grammar mirrors the one the Stryker ecosystem uses, because somebody arriving from
/// another language should not have to learn a second one:
///
/// ```swift
/// // swift-mutants disable next-line comparison: unsigned, so <= is equivalent
/// // swift-mutants disable all
/// // swift-mutants restore all
/// ```
struct Suppressions {

    /// Families disabled for a specific line, one-based.
    private var byLine: [Int: Set<String>] = [:]

    /// A stretch of lines with some families turned off.
    private struct Region {
        let from: Int
        let until: Int
        let families: Set<String>
    }

    /// Families disabled from a line onwards, until restored.
    private var regions: [Region] = []

    /// Every line a suppression comment was written on, for the skip record.
    private(set) var commentLines: [Int] = []

    /// Families named by a comment that this build has never heard of.
    ///
    /// Reported rather than ignored. A comment that silences nothing is worse than no
    /// comment at all: somebody wrote it, believed a mutant was dealt with, and the mutant
    /// is still there. A typo, a family renamed between releases, and a family from a
    /// sibling project all look like this, and all of them deserve to be told about.
    private(set) var unknownFamilies: [(line: Int, name: String)] = []

    init(source: String) {
        var open: [String: Int] = [:]
        for (number, text) in source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let line = number + 1
            guard let directive = Self.directive(in: String(text)) else { continue }
            commentLines.append(line)
            for family in directive.families
            where family != "all" && !Rules.families.contains(family) {
                unknownFamilies.append((line: line, name: family))
            }
            switch directive.action {
            case .disableNextLine:
                byLine[line + 1, default: []].formUnion(directive.families)
            case .disable:
                for family in directive.families { open[family] = line }
            case .restore:
                for family in directive.families {
                    guard let from = open.removeValue(forKey: family) else { continue }
                    regions.append(Region(from: from, until: line, families: [family]))
                }
            }
        }
        // A region nobody closed runs to the end of the file, which is what somebody who
        // wrote `disable all` at the top of a file meant.
        let lastLine = source.split(separator: "\n", omittingEmptySubsequences: false).count
        for (family, from) in open {
            regions.append(Region(from: from, until: lastLine + 1, families: [family]))
        }
    }

    /// Whether a family is disabled on a line.
    ///
    /// `all` disables everything, which is what somebody writing it expects and what makes
    /// the common case one word.
    func disables(_ family: String, onLine line: Int) -> Bool {
        if let families = byLine[line], families.contains(family) || families.contains("all") {
            return true
        }
        for region in regions {
            guard region.from < line, line < region.until else { continue }
            if region.families.contains(family) || region.families.contains("all") { return true }
        }
        return false
    }

    /// The index just past `needle`, without reaching for Foundation.
    ///
    /// Discovery has no other need for it, and a module that imports nothing is a module
    /// whose behaviour cannot change underneath it.
    private static func index(after needle: String, in haystack: String) -> String.Index? {
        let wanted = Array(needle)
        let characters = Array(haystack)
        guard characters.count >= wanted.count else { return nil }
        for start in 0...(characters.count - wanted.count)
        where Array(characters[start..<(start + wanted.count)]) == wanted {
            return haystack.index(haystack.startIndex, offsetBy: start + wanted.count)
        }
        return nil
    }

    private enum Action {
        case disable
        case disableNextLine
        case restore
    }

    private static func directive(in line: String) -> (action: Action, families: Set<String>)? {
        guard let marker = Self.index(after: "// swift-mutants ", in: line) else { return nil }
        var rest = line[marker...]
        // Anything after a colon is a reason for a person, not an instruction.
        if let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }

        let words = rest.split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let verb = words.first else { return nil }

        var remaining = Array(words.dropFirst())
        let action: Action
        switch verb {
        case "disable" where remaining.first == "next-line":
            action = .disableNextLine
            remaining.removeFirst()
        case "disable":
            action = .disable
        case "restore":
            action = .restore
        default:
            return nil
        }
        guard !remaining.isEmpty else { return nil }
        return (action, Set(remaining))
    }
}
