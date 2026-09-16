// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// The ends of a collection, swapped for each other.
///
/// Every other rule here changes an operator. This one changes a *name* - `first` for
/// `last`, `min` for `max`, `prefix` for `suffix` - and the names come in pairs that mean
/// opposite ends of the same sequence. A suite that cannot tell one end from the other is
/// a suite that would not have caught the day somebody wrote the wrong one.
///
/// Swift's standard library is unusually good for this. The pairs are spelled the same way
/// everywhere, return the same type as each other by construction, and are used constantly
/// - which is three of the things that make a mutation operator worth having.
@Suite("The ends of a collection")
struct CollectionBoundaryTests {

    static func discover(_ source: String) -> FileDiscovery {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        return Discover.candidates(in: source, at: path, selecting: mutation)
    }

    static func swaps(_ source: String) -> [String] {
        Self.discover(source)
            .candidates.filter { $0.rule.name.hasPrefix("swap-") }.map(\.replacement)
    }

    @Test(
        "swaps one end of a collection for the other",
        arguments: [
            ("let v = xs.first", "last"),
            ("let v = xs.last", "first"),
            ("let v = xs.min()", "max"),
            ("let v = xs.max()", "min"),
            ("let v = xs.prefix(3)", "suffix"),
            ("let v = xs.suffix(3)", "prefix"),
            ("let v = xs.dropFirst()", "dropLast"),
            ("let v = xs.dropLast()", "dropFirst"),
            ("let v = s.hasPrefix(p)", "hasSuffix"),
            ("let v = s.hasSuffix(p)", "hasPrefix"),
            ("let v = xs.firstIndex(of: n)", "lastIndex"),
            ("let v = xs.removeFirst()", "removeLast"),
        ]
    )
    func swapsEnds(source: String, expected: String) {
        #expect(Self.swaps(source) == [expected], "\(source)")
    }

    /// The member is what is replaced, not the expression around it: the receiver keeps its
    /// own bytes, so a receiver with its own mutants in it still has them.
    @Test("replaces only the name")
    func onlyTheName() {
        let found = Self.discover("let v = xs.dropFirst(n + 1).first")
        #expect(found.candidates.contains { $0.rule.name == "add-to-sub" })
        #expect(Self.swaps("let v = xs.dropFirst(n + 1).first").sorted() == ["dropLast", "last"])
    }

    /// A guard around a member access has to wrap the whole **call** when there is one. A
    /// ternary around `xs.dropFirst` alone is a ternary of two unapplied method references
    /// that something then calls: it does not type-check, it loses every default argument,
    /// and for a `mutating` method it cannot be written at all.
    @Test("wraps the whole call for a method, and the access alone for a property")
    func guardsTheCall() {
        let method = Self.discover("let v = xs.dropFirst()")
            .candidates.first { $0.rule.name == "swap-drop-last" }
        // `xs.dropFirst()` is fourteen bytes from `xs`; the access alone is twelve.
        #expect(method?.guardSpan.end == 8 + 14, "\(String(describing: method?.guardSpan))")

        let property = Self.discover("let v = xs.first")
            .candidates.first { $0.rule.name == "swap-last" }
        #expect(property?.guardSpan.end == 8 + 8, "\(String(describing: property?.guardSpan))")
    }

    /// A name that is not one of the pairs is left alone. This rule knows a fixed list and
    /// guesses at nothing: `firstResponder` is not an end of a collection.
    @Test(
        "leaves a name that is not one of the pairs alone",
        arguments: ["let v = view.firstResponder", "let v = x.minimum", "let v = a.prefixLength"]
    )
    func leavesOthers(source: String) {
        #expect(Self.swaps(source).isEmpty, "\(source)")
    }

    /// A rule name goes into a mutant's identity and into every report that mentions it,
    /// and is spelled the way every other rule is. `RuleIdentifier` refuses anything else,
    /// which is how the first version of this family was found: every one of its rules was
    /// named `swap-dropLast` and every one of them trapped.
    @Test("names its rules the way every other rule is named")
    func ruleNames() {
        let found = Set(
            Self.discover("let v = xs.dropFirst().hasPrefix(p)")
                .candidates.map(\.rule.name))
        #expect(found.contains("swap-drop-last"), "\(found)")
        #expect(found.contains("swap-has-suffix"), "\(found)")
    }

    /// A declaration of one's own with one of these names is still a member access and is
    /// still swapped. That is deliberate: this rule cannot know whose `first` it is, and a
    /// mutant the compiler refuses is reported with the compiler's words rather than
    /// guessed away - which is the same bargain every rule here makes.
    @Test("is in the tier that says it is")
    func tier() {
        #expect(RuleSelection.everyFamily.contains("collection-boundary"))
    }
}
