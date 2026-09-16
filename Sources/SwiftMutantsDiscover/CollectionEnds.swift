// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftSyntax

/// The ends of a collection, and the names Swift spells them with.
///
/// Every other rule in this catalogue changes an operator. This one changes a *name*, and
/// it works because Swift's standard library spells the two ends of a sequence in matched
/// pairs: `first` and `last`, `min` and `max`, `prefix` and `suffix`. Each pair returns the
/// same type as its partner by construction, which is what lets a ternary guard hold both.
///
/// A suite that cannot tell one end from the other is a suite that would not have caught
/// the day somebody wrote the wrong one - and writing the wrong one is easy, because the
/// two are the same length, the same shape, and next to each other in every autocomplete
/// list there has ever been.
///
/// A fixed list, and nothing is guessed. `firstResponder` is not an end of a collection,
/// and a rule that matched on a prefix would say it was.
enum CollectionEnds {

    /// The other end of the collection, by the name this one is spelled with.
    static func opposite(of name: String) -> String? { Self.pairs[name] }

    /// Every name in every pair, which is how the catalogue knows the rules exist.
    static var everyName: [String] { Array(Self.pairs.keys) }

    /// A rule name for the end being named, spelled the way every other rule is.
    ///
    /// Kebab-case, because a rule name goes into a mutant's identity and into every report
    /// that mentions it, and `RuleIdentifier` refuses anything else - which is how this was
    /// found. `dropLast` becomes `swap-drop-last`, and the *replacement* stays the Swift
    /// spelling, because that is what goes in the file.
    static func ruleName(for name: String) -> String {
        var rendered = "swap"
        var word = ""
        for character in name {
            if character.isUppercase {
                rendered += "-\(word)"
                word = character.lowercased()
            } else {
                word.append(character)
            }
        }
        return "\(rendered)-\(word)"
    }

    /// Both directions of every pair, built from one list so the two can never disagree.
    ///
    /// Written once as the pairs they are: a table with `first: last` and `last: first` in
    /// it by hand is a table where somebody eventually adds one line and not the other.
    private static let pairs: [String: String] = {
        var table: [String: String] = [:]
        for (one, other) in Self.both {
            table[one] = other
            table[other] = one
        }
        return table
    }()

    /// Each pair once, in the direction it reads.
    ///
    /// `removeFirst`/`removeLast` and `popLast` have no partner that is not also a mutation
    /// of what the collection is left as, which is a different question; only the ones
    /// whose two halves differ in *which end* and nothing else are here.
    private static let both: [(String, String)] = [
        ("first", "last"),
        ("min", "max"),
        ("prefix", "suffix"),
        ("dropFirst", "dropLast"),
        ("hasPrefix", "hasSuffix"),
        ("firstIndex", "lastIndex"),
        ("removeFirst", "removeLast"),
    ]
}
