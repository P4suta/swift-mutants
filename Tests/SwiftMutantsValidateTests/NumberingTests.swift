// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import Testing

@testable import SwiftMutantsValidate

/// One environment variable, one mutant awake.
///
/// Every instrumented file reads the same `SWIFT_MUTANTS_ACTIVE`, so numbering each file
/// from zero means one value wakes the same index in all of them. Measured on this
/// repository before the numbering ran through: fifty-nine files, so a run asking for
/// mutant 3 woke up to fifty-nine at once - and reported what it learned as a fact about
/// one of them, which is how a suite with real holes in it scored a hundred per cent.
@Suite("Numbering across a package")
struct NumberingTests {

    static func scratch() throws -> ValidatorTests.Scratch { try ValidatorTests.scratch() }

    static func subject(_ source: String, named name: String) -> FileUnderValidation {
        ValidatorTests.subject(source, named: name)
    }

    @Test("gives no two mutants in a package the same index")
    func indicesAreUniqueAcrossFiles() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }

        let validated = try await Validator(
            compiler: ValidatorTests.Stub(refusing: []), directory: scratch.directory
        ).validate([
            Self.subject("func a(_ x: Int, _ y: Int) -> Bool { x < y && x > y }", named: "A.swift"),
            Self.subject("func b(_ x: Int, _ y: Int) -> Bool { x != y }", named: "B.swift"),
            Self.subject("func c(_ x: Bool) -> Bool { x == true }", named: "C.swift"),
        ])

        let indices = validated.files.flatMap { $0.instrumented.mutants.map(\.index) }
        #expect(indices.count > 3)
        #expect(Set(indices).count == indices.count, "two mutants share an index: \(indices)")
    }

    /// And they stay contiguous from zero, because the runtime compares one integer and a
    /// gap is a number nothing answers to.
    @Test("numbers them contiguously from zero")
    func contiguous() async throws {
        let scratch = try Self.scratch()
        defer { scratch.cleanUp() }

        let validated = try await Validator(
            compiler: ValidatorTests.Stub(refusing: []), directory: scratch.directory
        ).validate([
            Self.subject("func a(_ x: Int, _ y: Int) -> Bool { x < y }", named: "A.swift"),
            Self.subject("func b(_ x: Int, _ y: Int) -> Bool { x > y }", named: "B.swift"),
        ])

        let indices = validated.files.flatMap { $0.instrumented.mutants.map(\.index) }.sorted()
        #expect(indices == Array(0..<UInt32(indices.count)))
    }
}
