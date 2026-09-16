// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import Testing

@testable import SwiftMutantsDiscover

/// Swapping one arithmetic operator for another.
///
/// The oldest mutation there is, and still among the most productive: an off-by-one in a
/// total, a division where a multiplication belonged. A suite that computes a number and
/// never checks it will not notice, which is the point.
///
/// Paired rather than exhaustive. `+` becomes `-` and `-` becomes `+`; it does not also
/// become `*`, `/` and `%`. The full cross-product is where a catalogue's redundancy comes
/// from - several mutants at one site that the same test kills - and Google's measurements
/// on six years of a monorepo put the productivity of exhaustive operator replacement at
/// the bottom of the table.
///
/// Shifts and bitwise operators live in the same table because they are the same kind of
/// edit on the same kind of expression, even though they are reached by a different tier.
@Suite("Arithmetic")
struct ArithmeticTests {

    static func path() -> WorkspaceRelativePath {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return path
    }

    static func found(_ expression: String) -> [Candidate] {
        Discover.candidates(
            in: "func f(_ a: Int, _ b: Int) -> Int { \(expression) }", at: Self.path()
        ).candidates
    }

    @Test(
        "swaps each arithmetic operator for its pair",
        arguments: [
            ("a + b", "add-to-sub", "+", "-"),
            ("a - b", "sub-to-add", "-", "+"),
            ("a * b", "mul-to-div", "*", "/"),
            ("a / b", "div-to-mul", "/", "*"),
            ("a % b", "rem-to-mul", "%", "*"),
        ])
    func pairs(expression: String, rule: String, original: String, replacement: String) {
        let found = Self.found(expression)
        #expect(found.map(\.rule.name) == [rule])
        #expect(found.map(\.original) == [original])
        #expect(found.map(\.replacement) == [replacement])
    }

    @Test(
        "swaps each compound assignment for its pair",
        arguments: [
            ("+=", "add-assign-to-sub-assign", "-="),
            ("-=", "sub-assign-to-add-assign", "+="),
            ("*=", "mul-assign-to-div-assign", "/="),
            ("/=", "div-assign-to-mul-assign", "*="),
        ])
    func compoundAssignments(spelled: String, rule: String, replacement: String) {
        // Filtered to the operator, because a statement is also a site: `c += b` is both
        // an assignment to swap and a statement to skip, and a test that asserted the whole
        // catalogue would be a test about every rule this tool will ever have.
        let found = Discover.candidates(
            in: "func f(_ a: Int, _ b: Int) { var c = a; c \(spelled) b; _ = c }",
            at: Self.path()
        ).candidates.filter { $0.rule.name == rule }
        #expect(found.count == 1)
        #expect(found.map(\.replacement) == [replacement])
    }

    @Test(
        "swaps each bitwise operator and shift",
        arguments: [
            ("a & b", "bitand-to-bitor"),
            ("a | b", "bitor-to-bitand"),
            ("a ^ b", "xor-to-bitand"),
            ("a << b", "shl-to-shr"),
            ("a >> b", "shr-to-shl"),
        ])
    func bitwise(expression: String, rule: String) {
        #expect(Self.found(expression).map(\.rule.name) == [rule])
    }

    /// Precedence is resolved before any of this, so `a + b * c` is two sites rather than
    /// one flat sequence to guess at.
    @Test("takes the operands precedence gives each operator")
    func respectsPrecedence() {
        let found = Discover.candidates(
            in: "func f(_ a: Int, _ b: Int, _ c: Int) -> Int { a + b * c }", at: Self.path()
        ).candidates
        #expect(found.map(\.rule.name).sorted() == ["add-to-sub", "mul-to-div"])

        let bytes = Array("func f(_ a: Int, _ b: Int, _ c: Int) -> Int { a + b * c }".utf8)
        let wrapped = found.map {
            String(decoding: bytes[$0.guardSpan.start..<$0.guardSpan.end], as: UTF8.self)
        }
        #expect(Set(wrapped) == ["a + b * c", "b * c"])
    }

    /// A unary minus is not a subtraction, and reading it as one would produce `a + -b`
    /// out of `-b` - a different expression that happens to compile.
    ///
    /// The *arithmetic* rules, not the whole catalogue: a unary minus has a rule of its
    /// own - `drop-negation`, which takes it away - and this is the claim that the
    /// arithmetic walk does not also read it as a subtraction.
    @Test("leaves a unary minus alone")
    func unaryMinus() {
        #expect(!Self.found("-a").contains { $0.rule.name.hasSuffix("-to-sub") })
        #expect(!Self.found("-a").contains { $0.rule.name.hasSuffix("-to-add") })
    }

    /// `+` on strings and arrays is concatenation, and `-` is not defined for either. The
    /// mutant is emitted anyway: the compiler is what decides which mutants exist, and a
    /// tool that guessed at types without having any would guess wrong in both directions.
    @Test("offers the swap and lets the compiler refuse it")
    func typesAreTheCompilersBusiness() {
        let found = Discover.candidates(
            in: #"func f(_ a: String, _ b: String) -> String { a + b }"#, at: Self.path()
        ).candidates
        #expect(found.map(\.rule.name) == ["add-to-sub"])
    }

    /// The escape hatch names families, so one comment silences the site.
    @Test("obeys the comment that names its family")
    func obeysSuppression() {
        let found = Discover.candidates(
            in: """
                func f(_ a: Int, _ b: Int) -> Int {
                    // swift-mutants disable next-line integer-arithmetic: checked elsewhere
                    return a + b
                }
                """,
            at: Self.path()
        )
        #expect(found.candidates.isEmpty)
        #expect(found.skips.contains { $0.reason == .disabledByComment })
    }
}

/// Comments that ask for something this build does not have.
///
/// A suppression comment that silences nothing is worse than no comment at all: somebody
/// wrote it, believed a mutant was dealt with, and it is still there. A typo, a family
/// renamed between releases, and a family borrowed from a sibling project all look like
/// this from here, and all of them deserve to be named.
@Suite("Unknown suppressions")
struct UnknownSuppressionTests {

    static func found(_ source: String) -> [UnknownSuppression] {
        guard let path = WorkspaceRelativePath("Sources/Subject.swift") else {
            fatalError("malformed fixture path")
        }
        return Discover.candidates(in: source, at: path).unknownSuppressions
    }

    @Test("names a family this build has never heard of")
    func namesTheTypo() {
        let found = Self.found(
            """
            func f(_ a: Int, _ b: Int) -> Int {
                // swift-mutants disable next-line comparisons: a typo for `comparison`
                return a + b
            }
            """
        )
        #expect(found.map(\.name) == ["comparisons"])
        #expect(found.map(\.line) == [2])
    }

    @Test("says nothing about a family it does have")
    func knownFamily() {
        #expect(
            Self.found(
                """
                func f(_ a: Int, _ b: Int) -> Int {
                    // swift-mutants disable next-line integer-arithmetic: checked elsewhere
                    return a + b
                }
                """
            ).isEmpty
        )
    }

    /// `all` is the one word that names no family and means all of them.
    @Test("says nothing about all")
    func allIsNotAFamily() {
        #expect(
            Self.found(
                """
                // swift-mutants disable all
                func f(_ a: Int, _ b: Int) -> Int { a + b }
                """
            ).isEmpty
        )
    }

    @Test("names each one when a comment lists several")
    func severalAtOnce() {
        let found = Self.found(
            """
            func f(_ a: Int, _ b: Int) -> Int {
                // swift-mutants disable next-line comparison,arithmetics: half wrong
                return a + b
            }
            """
        )
        #expect(found.map(\.name) == ["arithmetics"])
    }
}

/// Arithmetic on things that are visibly not numbers.
///
/// `+` is the one arithmetic operator Swift also gives to strings and collections, and it
/// is the only one it gives them: `["a"] - ["b"]` is not a program. So every arithmetic
/// mutant at such a site is a rejection decided in advance - the compiler will refuse it,
/// the run pays a whole build to be told so, and the mutant is worth nothing either way.
///
/// Worse than worthless, in fact. A guard whose two branches differ by an operator adds an
/// overload choice to the expression around it, and `+` over array literals is already the
/// shape the Swift type checker struggles with (SR-1577): it gave up on two such sites in
/// this package's own sources with "unable to type-check this expression in reasonable
/// time". A compile that ends that way says nothing about any particular mutant, so the
/// run falls back to halving its way through the catalogue - the most expensive path there
/// is, entered for a mutant that could never have compiled.
///
/// Syntax cannot tell what `a + b` is. It can tell what `a + ["b"]` is, and that is where
/// the cost is.
@Suite("Arithmetic on what is visibly not a number")
struct NonNumericArithmeticTests {

    static func found(_ expression: String) -> FileDiscovery {
        Discover.candidates(
            in: "func f(_ a: [String], _ b: [String]) -> [String] { \(expression) }",
            at: ArithmeticTests.path()
        )
    }

    static func names(_ expression: String) -> [String] {
        Self.found(expression).candidates.map(\.rule.name)
    }

    /// No *arithmetic* swap. `+` to `-` on two arrays does not compile, so offering it
    /// would be offering a mutant the compiler is certain to refuse.
    ///
    /// The concatenation turning round is a different question and is offered - see
    /// `ConcatenationTests`. This asserted that such a line produced nothing at all, which
    /// was true while it did and is the thing that changed.
    @Test(
        "offers no arithmetic swap for an operand that is a literal of the wrong kind",
        arguments: [
            #"a + ["x"]"#,
            #"["x"] + a"#,
            #""x" + "y""#,
            #"a + [1: "x"]"#,
        ]
    )
    func passesOverLiteralOperands(_ expression: String) {
        #expect(!Self.names(expression).contains("add-to-sub"), "\(Self.names(expression))")
    }

    /// Folding turns `x + y + z` into `(x + y) + z`, so a literal buried on the left of a
    /// chain is still what the whole chain produces. `SwiftcDriver.typecheck` is written
    /// exactly this way, and its outer `+` is one of the two the compiler gave up on.
    @Test("follows a chain to the literal at the end of it")
    func followsAChain() {
        #expect(!Self.names(#"["x"] + a + b"#).contains("add-to-sub"))
        #expect(!Self.names(#"(["x"] + a) + b"#).contains("add-to-sub"))
    }

    /// Skips are counted and named, never dropped. A reader who wonders why a `+` they can
    /// see has no mutant gets an answer rather than a silence.
    @Test("says so, and says how many it hid")
    func saysSo() {
        let discovery = Self.found(#"a + ["x"]"#)
        #expect(discovery.skips.map(\.reason) == [.nonNumericOperand])
        #expect(discovery.skips.first?.candidatesHidden == 1)
    }

    /// The compiler is the right judge of everything syntax cannot see. Two names could be
    /// two integers, and refusing to mutate them would lose real mutants to a guess.
    @Test("leaves arithmetic between names alone")
    func leavesNamesAlone() {
        // The arithmetic rule, not the whole catalogue. `a + 1` holds a literal, and a
        // literal has rules of its own in the tier above; what this asserts is that the
        // operand being a name rather than a visible non-number leaves the *swap* in place.
        #expect(Self.names("a + b").filter { $0 == "add-to-sub" } == ["add-to-sub"])
        #expect(Self.names("a + 1").filter { $0 == "add-to-sub" } == ["add-to-sub"])
    }

    /// `xs += [x]` is real Swift and `xs -= [x]` is not, so the compound form is a decided
    /// rejection for the same reason.
    @Test("passes over the compound form too")
    func compoundForm() {
        #expect(
            Discover.candidates(
                in: #"func f(_ a: inout [String]) { a += ["x"] }"#, at: ArithmeticTests.path()
            ).candidates.isEmpty
        )
    }
}
