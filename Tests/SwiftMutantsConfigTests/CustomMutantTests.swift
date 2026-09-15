// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsConfig

/// Mutants a project writes for itself.
///
/// The operator catalogue asks "is this operator correct". A project's own mutants usually
/// ask something else - is this sort load-bearing, does this tie-break matter, is this
/// normalisation ever observed - and that question needs the project to answer it.
///
/// Measured on a real package whose author had accumulated 290 hand-written mutations:
/// twenty of them were reproduced by a generated operator flip, and about a hundred fall
/// into families a tool could learn to generate. The remaining two thirds need the project,
/// and nothing a catalogue can be taught will reach them.
///
/// Everything already built applies to them unchanged: content-addressed identity, the
/// outcome cache, coverage-directed test selection, batching, `explain`. What is needed is
/// somewhere to write them down.
@Suite("Mutants a project writes for itself")
struct CustomMutantTests {

    static func read(_ toml: String) throws -> [Configuration.Custom] {
        try Configuration(TOMLParser.parse(toml)).mutation.custom
    }

    static let one = """
        [[mutation.custom]]
        file = "Sources/Layout.swift"
        find = "wrong.sorted()"
        replace = "wrong"
        reason = "is the sort load-bearing"
        """

    @Test("reads one a project wrote")
    func readsOne() throws {
        let custom = try Self.read(Self.one)
        #expect(custom.count == 1)
        #expect(custom.first?.file == "Sources/Layout.swift")
        #expect(custom.first?.find == "wrong.sorted()")
        #expect(custom.first?.replace == "wrong")
        #expect(custom.first?.reason == "is the sort load-bearing")
        #expect(custom.first?.line == nil)
    }

    @Test("reads a line when one is given to tell two the same apart")
    func readsALine() throws {
        let custom = try Self.read(Self.one + "\nline = 42\n")
        #expect(custom.first?.line == 42)
    }

    @Test("reads a project with none in it")
    func readsNone() throws {
        #expect(try Self.read("[mutation]\nprofile = \"balanced\"\n").isEmpty)
    }

    /// Each field is needed, and saying which one is missing is the difference between a
    /// fix and a hunt.
    @Test(
        "says which field a row is missing",
        arguments: ["file", "find", "replace", "reason"])
    func missingField(_ field: String) throws {
        let without = Self.one
            .split(separator: "\n")
            .filter { !$0.hasPrefix("\(field) =") }
            .joined(separator: "\n")
        let error = #expect(throws: ConfigurationError.self) { try Self.read(without) }
        #expect(error?.reason.contains(field) == true)
    }

    /// An empty anchor matches everywhere and nowhere, and an empty reason leaves the next
    /// reader with a mutant and no idea what it was asking.
    @Test("refuses an empty field", arguments: ["find", "reason"])
    func emptyField(_ field: String) throws {
        let emptied = Self.one.replacingOccurrences(
            of: "\(field) = \"[^\"]*\"", with: "\(field) = \"\"", options: .regularExpression)
        #expect(throws: ConfigurationError.self) { try Self.read(emptied) }
    }

    /// An empty replacement is not a mistake: deleting a call is a mutation, and often the
    /// interesting one.
    @Test("allows an empty replacement, which is a deletion")
    func emptyReplacement() throws {
        let custom = try Self.read(Self.one.replacingOccurrences(of: #""wrong""#, with: #""""#))
        #expect(custom.first?.replace.isEmpty == true)
    }

    /// A replacement identical to what it replaces is a mutant that changes nothing, and a
    /// mutant that changes nothing survives every suite there will ever be.
    @Test("refuses a replacement that changes nothing")
    func noChange() throws {
        let same = Self.one.replacingOccurrences(
            of: #"replace = "wrong""#, with: #"replace = "wrong.sorted()""#)
        #expect(throws: ConfigurationError.self) { try Self.read(same) }
    }

    @Test("refuses a key it does not know")
    func unknownKey() throws {
        #expect(throws: ConfigurationError.self) { try Self.read(Self.one + "\nwhere = \"x\"\n") }
    }

    /// Two rows are allowed to name one file, and to name one anchor when they replace it
    /// differently - that is two questions about one place. Two rows identical in every
    /// field are one question written twice.
    @Test("refuses two rows that say the same thing")
    func duplicateRows() throws {
        #expect(throws: ConfigurationError.self) { try Self.read(Self.one + "\n" + Self.one) }
        #expect(
            try Self.read(
                Self.one + "\n"
                    + Self.one.replacingOccurrences(
                        of: #"replace = "wrong""#, with: #"replace = "[]""#)
            ).count == 2)
    }

    /// A line that is not a line is a typo that would otherwise anchor nothing.
    @Test("refuses a line that is not one", arguments: ["0", "-3"])
    func badLine(_ line: String) throws {
        #expect(throws: ConfigurationError.self) { try Self.read(Self.one + "\nline = \(line)\n") }
    }
}
