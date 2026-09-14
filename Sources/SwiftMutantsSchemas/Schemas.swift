// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
private import Synchronization

/// The documents this tool promises to write, and the shapes it promises they have.
///
/// Every document goes through here before it reaches a file or a pipe. Checking after the
/// fact would be checking what somebody has already read; checking before means a document
/// that does not keep the promise is never written at all.
public enum Schemas {

    /// The account a run gives of itself, which is what everything else is a projection of.
    public static let runReport = "run-report-v2.schema.json"

    /// What this tool writes for the Stryker ecosystem.
    ///
    /// A gate on this tool's own drift, not a conformance check on Stryker's shape: the
    /// document describes the subset swift-mutants emits, and says so.
    public static let strykerProjection = "stryker-projection-v1.schema.json"

    /// What this tool writes for anything that reads SARIF, GitHub code scanning first.
    public static let sarifProjection = "sarif-projection-v1.schema.json"

    /// A schema this tool ships, ready to check documents against.
    ///
    /// Read once and kept, because a schema is read far more often than it changes and
    /// parsing it per document would be parsing it per mutant in the limit.
    ///
    /// A schema that cannot be read is a defect in this tool rather than in anybody's
    /// package, and it stops the process here rather than becoming a report nobody checked.
    /// The alternative - carry on without checking - is the one failure this whole module
    /// exists to prevent.
    public static func schema(_ name: String) -> JSONSchema {
        guard
            let loaded = cache.withLock({ store -> JSONSchema? in
                if let known = store[name] { return known }
                guard let text = EmbeddedSchemas.byName[name],
                    let read = try? JSONSchema(Data(text.utf8))
                else { return nil }
                store[name] = read
                return read
            })
        else {
            fatalError(
                """
                swift-mutants ships no readable schema called \(name). This is a defect in \
                swift-mutants: run `mise run schema-embed` if you have just edited one.
                """
            )
        }
        return loaded
    }

    private static let cache = Mutex<[String: JSONSchema]>([:])

    /// A document that does not have the shape it promised.
    public struct Invalid: Error, Hashable, CustomStringConvertible {

        /// Which promise it broke.
        public let schema: String

        /// Everything wrong with it, in the order somebody would fix them.
        public let violations: [JSONSchema.Violation]

        /// Records a document that did not keep its promise.
        public init(schema: String, violations: [JSONSchema.Violation]) {
            self.schema = schema
            self.violations = violations
        }

        /// Everything wrong with it, and whose defect it is.
        public var description: String {
            """
            this would not have been a valid \(schema) document, so it was not written. \
            This is a defect in swift-mutants rather than in your package:
            \(violations.map { "  \($0)" }.joined(separator: "\n"))
            """
        }
    }

    /// Checks a document, or refuses it.
    ///
    /// - Throws: ``Invalid`` listing everything wrong, so one run says all of it rather than
    ///   one thing per run.
    public static func check(_ document: Data, against name: String) throws(Invalid) {
        let violations = schema(name).validate(document)
        guard violations.isEmpty else {
            throw Invalid(schema: name, violations: violations)
        }
    }
}
