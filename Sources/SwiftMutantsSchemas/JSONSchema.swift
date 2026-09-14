// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A document checked against the shape it claims to have.
///
/// A tool whose output is a promise has to keep it, and the way that breaks is quiet: a
/// field is renamed, a number becomes a string, an optional starts being omitted instead of
/// written as `null`. Every reader downstream then fails somewhere else, days later, with
/// an error about something else entirely.
///
/// So every document this tool writes is checked against the schema shipped beside it,
/// before it is written.
///
/// ## Why this rather than a library
///
/// The same reason the family writes its own glob engine and its own TOML reader: what a
/// document means must not depend on which version of somebody else's parser happens to be
/// installed. It is also a much smaller job than a general validator, because these
/// documents use a small fixed subset - and the subset is enforced rather than assumed.
///
/// ## Refusing what it cannot check
///
/// A schema using a keyword this does not implement is **refused when it is read**, not
/// ignored. That is the whole design. A validator that skips the constraints it does not
/// understand reports every document valid, which is worse than having no validator at all:
/// somebody writes a constraint, believes it is enforced, and it never was. Adding a
/// keyword to a schema here therefore fails loudly until it is implemented.
public struct JSONSchema: Sendable {

    /// One thing wrong with a document.
    public struct Violation: Sendable, Hashable, CustomStringConvertible {

        /// Where it is, as a JSON Pointer - `/mutants/3/outcome`.
        ///
        /// Because a document with four hundred mutants in it and one wrong field is
        /// unreadable without the path.
        public let path: String

        /// What is wrong, in the words a fix needs.
        public let message: String

        /// The place and the trouble, on one line.
        public var description: String { "\(path.isEmpty ? "/" : path): \(message)" }
    }

    /// A schema that could not be read.
    public struct MalformedSchema: Error, Hashable, CustomStringConvertible {
        /// What is wrong with the schema, in the words a fix needs.
        public let description: String
    }

    /// The keywords this understands. Anything else is refused.
    private static let known: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items", "enum", "minimum",
        "const", "$ref", "$defs",
    ]

    /// The words that describe a schema rather than constrain a document.
    ///
    /// Ignored rather than refused, because ignoring an annotation is not ignoring a
    /// constraint: there is nothing there to check.
    private static let annotations: Set<String> = [
        "title", "description", "$schema", "$id", "$comment", "examples", "default",
    ]

    private let root: JSONValue
    private let definitions: [String: JSONValue]

    /// Reads a schema, or refuses it.
    ///
    /// - Throws: ``MalformedSchema`` when the document is not an object, uses a keyword this
    ///   cannot check, or names a definition that is not there.
    public init(_ document: Data) throws(MalformedSchema) {
        guard let parsed = try? JSONValue(document), let root = parsed.fields else {
            throw MalformedSchema(description: "a schema is a JSON object")
        }
        self.root = parsed
        self.definitions = root["$defs"]?.fields ?? [:]
        for (name, nested) in definitions.sorted(by: { $0.key < $1.key }) {
            try Self.check(nested, at: "#/$defs/\(name)", definitions: definitions)
        }
        try Self.check(parsed, at: "#", definitions: definitions)
    }

    /// Walks a schema before anything is validated against it, refusing what it cannot check
    /// and what it cannot resolve.
    ///
    /// Done once, when the schema is read, so a broken schema is a broken schema rather than
    /// a document that happened to pass.
    private static func check(
        _ schema: JSONValue,
        at place: String,
        definitions: [String: JSONValue]
    ) throws(MalformedSchema) {
        guard let fields = schema.fields else {
            throw MalformedSchema(description: "\(place) is not a schema")
        }
        for key in fields.keys.sorted()
        where !known.contains(key) && !annotations.contains(key) {
            throw MalformedSchema(
                description: """
                    \(place) uses "\(key)", which this validator does not implement - a \
                    constraint it skipped would be a constraint nobody is enforcing
                    """
            )
        }
        if let reference = fields["$ref"]?.text {
            guard let name = Self.definitionName(of: reference), definitions[name] != nil else {
                throw MalformedSchema(
                    description: "\(place) refers to \(reference), which is not in $defs")
            }
        }
        for (name, nested) in (fields["properties"]?.fields ?? [:]).sorted(by: {
            $0.key < $1.key
        }) {
            try check(nested, at: "\(place)/properties/\(name)", definitions: definitions)
        }
        if let items = fields["items"] {
            try check(items, at: "\(place)/items", definitions: definitions)
        }
        if let extra = fields["additionalProperties"], extra.fields != nil {
            try check(extra, at: "\(place)/additionalProperties", definitions: definitions)
        }
    }

    /// The name a local reference points at, or nothing if it points elsewhere.
    ///
    /// Only `#/$defs/<name>` is understood. A reference to another file would be a document
    /// this tool does not ship, and resolving one would mean reading whatever is at that
    /// path when the tool happens to run.
    private static func definitionName(of reference: String) -> String? {
        let prefix = "#/$defs/"
        guard reference.hasPrefix(prefix) else { return nil }
        let name = String(reference.dropFirst(prefix.count))
        return name.isEmpty || name.contains("/") ? nil : name
    }

    /// Everything wrong with a document, or nothing.
    ///
    /// Every violation, not the first: somebody fixing a document wants the list, and a
    /// validator that stopped at the first mistake makes them run it once per mistake.
    public func validate(_ document: Data) -> [Violation] {
        guard let instance = try? JSONValue(document) else {
            return [Violation(path: "", message: "this is not JSON")]
        }
        return validate(instance)
    }

    /// The same, for a value that has already been read.
    public func validate(_ instance: JSONValue) -> [Violation] {
        var found: [Violation] = []
        check(instance, against: root, at: "", into: &found)
        return found
    }

    /// One value against one schema, gathering what is wrong rather than stopping.
    private func check(
        _ instance: JSONValue,
        against schema: JSONValue,
        at path: String,
        into found: inout [Violation]
    ) {
        guard let fields = schema.fields else { return }
        if let reference = fields["$ref"]?.text,
            let name = Self.definitionName(of: reference),
            let resolved = definitions[name]
        {
            check(instance, against: resolved, at: path, into: &found)
            return
        }
        if let names = Self.types(of: fields) {
            guard names.contains(where: instance.isOfType) else {
                found.append(
                    Violation(
                        path: path,
                        message: """
                            expected \(names.sorted().joined(separator: " or ")), \
                            found \(instance.typeName)
                            """
                    ))
                return
            }
        }
        Self.checkValue(instance, against: fields, at: path, into: &found)
        if instance.fields != nil {
            checkObject(instance, against: fields, at: path, into: &found)
        }
        if let elements = instance.elements, let items = fields["items"] {
            for (offset, element) in elements.enumerated() {
                check(element, against: items, at: "\(path)/\(offset)", into: &found)
            }
        }
    }

    /// The constraints that are about a value rather than about its shape.
    private static func checkValue(
        _ instance: JSONValue,
        against schema: [String: JSONValue],
        at path: String,
        into found: inout [Violation]
    ) {
        if let allowed = schema["enum"]?.elements, !allowed.contains(instance) {
            found.append(
                Violation(
                    path: path,
                    message: "\(instance.rendered) is not one of the values this allows"))
        }
        if let only = schema["const"], only != instance {
            found.append(
                Violation(
                    path: path,
                    message: "expected \(only.rendered), found \(instance.rendered)"))
        }
        if let floor = schema["minimum"]?.magnitude, let magnitude = instance.magnitude,
            magnitude < floor
        {
            found.append(
                Violation(path: path, message: "\(instance.rendered) is below \(floor)"))
        }
    }

    /// An object's required keys, its declared properties, and whatever else it holds.
    private func checkObject(
        _ instance: JSONValue,
        against schema: [String: JSONValue],
        at path: String,
        into found: inout [Violation]
    ) {
        guard let object = instance.fields else { return }
        let properties = schema["properties"]?.fields ?? [:]
        for name in (schema["required"]?.elements ?? []).compactMap(\.text)
        where object[name] == nil {
            found.append(Violation(path: path, message: "\"\(name)\" is missing"))
        }
        for (name, value) in object.sorted(by: { $0.key < $1.key }) {
            if let nested = properties[name] {
                check(value, against: nested, at: "\(path)/\(name)", into: &found)
                continue
            }
            switch schema["additionalProperties"] {
            case .some(let nested) where nested.fields != nil:
                check(value, against: nested, at: "\(path)/\(name)", into: &found)
            case .boolean(false):
                found.append(
                    Violation(path: path, message: "\"\(name)\" is not declared by the schema"))
            default:
                break
            }
        }
    }

    /// The types a schema allows, as a set, or nothing when it does not say.
    private static func types(of schema: [String: JSONValue]) -> Set<String>? {
        switch schema["type"] {
        case .string(let one): [one]
        case .array(let many): Set(many.compactMap(\.text))
        default: nil
        }
    }
}
