// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsSchemas

/// Checking a document against the shape it claims to have.
///
/// A tool whose output is a promise has to keep the promise, and the way that breaks is
/// quiet: a field is renamed, a number becomes a string, an optional starts being omitted
/// instead of written as `null`. Every reader downstream then fails at a different place,
/// days later, with an error about something else.
///
/// So documents are checked against the schema shipped beside them, before they are
/// written. The subset of JSON Schema here is the subset the documents use - and refusing a
/// keyword it does not implement is part of the design, because a validator that silently
/// ignores a constraint is a validator that reports everything valid.
@Suite("JSON Schema")
struct JSONSchemaTests {

    static func schema(_ text: String) throws -> JSONSchema {
        try JSONSchema(Data(text.utf8))
    }

    static func violations(_ schema: String, _ instance: String) throws -> [JSONSchema.Violation] {
        try Self.schema(schema).validate(Data(instance.utf8))
    }

    static func accepts(_ schema: String, _ instance: String) throws -> Bool {
        try Self.violations(schema, instance).isEmpty
    }

    // MARK: - type

    @Test(
        "accepts a value of the type it asks for",
        arguments: [
            (#"{"type": "string"}"#, #""a""#),
            (#"{"type": "integer"}"#, "1"),
            (#"{"type": "number"}"#, "1.5"),
            (#"{"type": "number"}"#, "1"),
            (#"{"type": "boolean"}"#, "true"),
            (#"{"type": "null"}"#, "null"),
            (#"{"type": "array"}"#, "[]"),
            (#"{"type": "object"}"#, "{}"),
        ])
    func acceptsItsType(_ schema: String, _ instance: String) throws {
        #expect(try Self.accepts(schema, instance))
    }

    @Test(
        "refuses a value of another type",
        arguments: [
            (#"{"type": "string"}"#, "1"),
            (#"{"type": "integer"}"#, #""1""#),
            (#"{"type": "integer"}"#, "1.5"),
            (#"{"type": "boolean"}"#, "1"),
            (#"{"type": "null"}"#, "0"),
            (#"{"type": "array"}"#, "{}"),
            (#"{"type": "object"}"#, "[]"),
            (#"{"type": "string"}"#, "null"),
        ])
    func refusesAnotherType(_ schema: String, _ instance: String) throws {
        #expect(try !Self.accepts(schema, instance))
    }

    /// How every optional in these documents is spelled: a value or `null`, never absent.
    @Test("accepts either of a pair of types")
    func acceptsEitherType() throws {
        let schema = #"{"type": ["integer", "null"]}"#
        #expect(try Self.accepts(schema, "1"))
        #expect(try Self.accepts(schema, "null"))
        #expect(try !Self.accepts(schema, #""1""#))
    }

    /// `true` is a boolean and `1` is not, however C thinks about it. A validator that let
    /// one through would pass a document no strict reader will parse.
    @Test("does not read a boolean as a number, or a number as a boolean")
    func booleansAreNotNumbers() throws {
        #expect(try !Self.accepts(#"{"type": "integer"}"#, "true"))
        #expect(try !Self.accepts(#"{"type": "boolean"}"#, "0"))
    }

    // MARK: - objects

    @Test("says which property is missing")
    func namesAMissingProperty() throws {
        let violations = try Self.violations(
            #"{"type": "object", "required": ["a", "b"]}"#, #"{"a": 1}"#)
        #expect(violations.count == 1)
        #expect(violations.first?.message.contains("b") == true)
    }

    @Test("checks each property against its own schema")
    func checksEachProperty() throws {
        let schema = #"{"properties": {"a": {"type": "integer"}}}"#
        #expect(try Self.accepts(schema, #"{"a": 1}"#))
        #expect(try !Self.accepts(schema, #"{"a": "one"}"#))
    }

    /// Says where, not just what. A document with four hundred mutants in it and one wrong
    /// field is unreadable without the path.
    @Test("says where in the document the trouble is")
    func namesThePlace() throws {
        let violations = try Self.violations(
            #"{"properties": {"a": {"items": {"properties": {"b": {"type": "integer"}}}}}}"#,
            #"{"a": [{"b": 1}, {"b": "no"}]}"#
        )
        #expect(violations.count == 1)
        #expect(violations.first?.path == "/a/1/b")
    }

    /// A key nobody declared is how a document drifts from its schema without anybody
    /// noticing, so every object in these documents closes itself.
    @Test("refuses a property nobody declared")
    func refusesAnUndeclaredProperty() throws {
        let schema = #"{"properties": {"a": {}}, "additionalProperties": false}"#
        #expect(try Self.accepts(schema, #"{"a": 1}"#))
        #expect(try !Self.accepts(schema, #"{"a": 1, "b": 2}"#))
    }

    /// A map whose keys are not known in advance - a file path to its digest, say - still
    /// says what its values are.
    @Test("checks the values of a map against one schema")
    func checksMapValues() throws {
        let schema = #"{"additionalProperties": {"type": "string"}}"#
        #expect(try Self.accepts(schema, #"{"any": "thing"}"#))
        #expect(try !Self.accepts(schema, #"{"any": 1}"#))
    }

    // MARK: - arrays

    @Test("checks every element against one schema")
    func checksEveryElement() throws {
        let schema = #"{"items": {"type": "integer"}}"#
        #expect(try Self.accepts(schema, "[1, 2, 3]"))
        #expect(try !Self.accepts(schema, #"[1, "2"]"#))
    }

    // MARK: - values

    @Test("refuses a value outside the set it names")
    func refusesAValueOutsideTheSet() throws {
        let schema = #"{"enum": ["killed", "survived"]}"#
        #expect(try Self.accepts(schema, #""killed""#))
        #expect(try !Self.accepts(schema, #""eaten""#))
    }

    @Test("refuses a number below the floor")
    func refusesANumberBelowTheFloor() throws {
        let schema = #"{"minimum": 0}"#
        #expect(try Self.accepts(schema, "0"))
        #expect(try !Self.accepts(schema, "-1"))
    }

    @Test("refuses a value other than the one it names")
    func refusesAnythingButTheConstant() throws {
        let schema = #"{"const": 2}"#
        #expect(try Self.accepts(schema, "2"))
        #expect(try !Self.accepts(schema, "3"))
    }

    // MARK: - references

    @Test("follows a reference to a definition")
    func followsAReference() throws {
        let schema = """
            {"$defs": {"count": {"type": "integer"}},
             "properties": {"a": {"$ref": "#/$defs/count"}}}
            """
        #expect(try Self.accepts(schema, #"{"a": 1}"#))
        #expect(try !Self.accepts(schema, #"{"a": "one"}"#))
    }

    /// A reference to nothing is a broken schema, and a validator that shrugged at one
    /// would report every document valid against it.
    @Test("refuses a schema whose reference points at nothing")
    func refusesADanglingReference() {
        #expect(throws: (any Error).self) {
            try Self.schema(##"{"properties": {"a": {"$ref": "#/$defs/missing"}}}"##)
        }
    }

    // MARK: - refusing what it cannot check

    /// The whole point. A validator that ignores the keywords it does not implement reports
    /// everything valid, which is worse than having no validator: somebody writes a
    /// constraint, believes it is enforced, and it never was.
    @Test(
        "refuses a schema using a keyword it cannot check",
        arguments: ["allOf", "not", "patternProperties", "if", "dependentRequired"])
    func refusesAnUnimplementedKeyword(_ keyword: String) {
        #expect(throws: (any Error).self) {
            try Self.schema("{\"\(keyword)\": {}}")
        }
    }

    /// Annotations say nothing about a document, so ignoring them is not ignoring a
    /// constraint.
    @Test(
        "reads past the words that describe rather than constrain",
        arguments: ["title", "description", "$schema", "$id", "$comment", "examples"])
    func readsPastAnnotations(_ keyword: String) throws {
        #expect(try Self.accepts("{\"\(keyword)\": \"x\", \"type\": \"integer\"}", "1"))
    }

    // MARK: - reporting

    /// Every one of them, not the first. Somebody fixing a document wants the list, and a
    /// validator that stopped at the first makes them run it once per mistake.
    @Test("reports every violation it finds")
    func reportsAllOfThem() throws {
        let violations = try Self.violations(
            """
            {"properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
             "required": ["c"]}
            """,
            #"{"a": "x", "b": "y"}"#
        )
        #expect(violations.count == 3)
    }

    @Test("refuses a document that is not JSON at all")
    func refusesNonsense() throws {
        let schema = try Self.schema(#"{"type": "object"}"#)
        #expect(schema.validate(Data("not json".utf8)).count == 1)
    }
}
