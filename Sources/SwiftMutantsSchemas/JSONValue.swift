// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A JSON document as a value.
///
/// `JSONSerialization` hands back `Any`, which Swift 6 will not let cross a concurrency
/// boundary and which cannot tell `true` from `1` without asking Core Foundation what kind
/// of `NSNumber` it is holding. Both problems are solved once, here, at the edge: after
/// this, a boolean is a boolean and nothing in the validator has to ask again.
public enum JSONValue: Sendable, Hashable {
    case null
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    /// A document could not be read as JSON.
    public struct NotJSON: Error, Hashable, CustomStringConvertible {
        /// What went wrong, in the words a fix needs.
        public let description: String
    }

    /// Reads a document, or says it is not one.
    public init(_ document: Data) throws(NotJSON) {
        guard
            let parsed = try? JSONSerialization.jsonObject(
                with: document, options: [.fragmentsAllowed])
        else {
            throw NotJSON(description: "this is not JSON")
        }
        self = Self(converting: parsed)
    }

    /// Turns what `JSONSerialization` produced into a value.
    ///
    /// The `NSNumber` question is settled here and nowhere else. A JSON `true` and a JSON
    /// `1` are both `NSNumber`s that answer to `boolValue` and `intValue`, so the only way
    /// to tell them apart is the Core Foundation type - and letting one pass for the other
    /// would accept a document no strict reader will parse.
    private init(converting object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { Self(converting: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { Self(converting: $0) })
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .boolean(number.boolValue)
            } else if let whole = Int(exactly: number.doubleValue) {
                self = .integer(whole)
            } else {
                self = .number(number.doubleValue)
            }
        default:
            self = .null
        }
    }

    /// The name this type goes by in a schema.
    public var typeName: String {
        switch self {
        case .null: "null"
        case .boolean: "boolean"
        case .integer: "integer"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    /// Whether this is a value of a named JSON type.
    ///
    /// An integer is also a number; a number that is not whole is not an integer; and a
    /// boolean is neither, whatever C thinks.
    public func isOfType(_ name: String) -> Bool {
        switch (name, self) {
        case ("number", .integer): true
        default: name == typeName
        }
    }

    /// What this looks like in a message somebody reads.
    public var rendered: String {
        switch self {
        case .null: "null"
        case .boolean(let value): "\(value)"
        case .integer(let value): "\(value)"
        case .number(let value): "\(value)"
        case .string(let value): "\"\(value)\""
        case .array: "an array"
        case .object: "an object"
        }
    }

    /// The fields, when this is an object.
    public var fields: [String: Self]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    /// The elements, when this is an array.
    public var elements: [Self]? {
        if case .array(let elements) = self { return elements }
        return nil
    }

    /// The text, when this is a string.
    public var text: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// The magnitude, when this is a number of either kind.
    public var magnitude: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }
}
