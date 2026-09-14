// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsSchemas
import SwiftMutantsTestKit
import Testing

/// The schema the tool carries is the schema the repository publishes.
///
/// There are two copies for a reason - the `.json` is what an outside reader consults, and
/// the embedded text is what the tool checks against, because a validator that could not
/// find its schema would have to choose between refusing to write anything and writing
/// without checking. Two copies of anything drift, so this is what stops them.
///
/// It fails on the edit, not on the release: somebody changing a schema and forgetting
/// `mise run schema-embed` finds out from this rather than from a document in the field
/// that was never checked against the shape it claims.
@Suite("Schemas do not drift")
struct SchemaDriftTests {

    static var published: [String: String] {
        get throws {
            let directory = RepositoryGate.root.appending(path: "schema")
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return try names.filter { $0.hasSuffix(".schema.json") }
                .reduce(into: [:]) { found, name in
                    found[name] = try String(
                        contentsOf: directory.appending(path: name), encoding: .utf8)
                }
        }
    }

    @Test("ships every schema the repository publishes")
    func shipsEveryOne() throws {
        #expect(try Set(Self.published.keys) == Set(EmbeddedSchemas.byName.keys))
        #expect(!EmbeddedSchemas.byName.isEmpty)
    }

    /// Byte for byte, trailing newline aside - the generator writes the literal without the
    /// file's final newline, and nothing else about the document may differ.
    @Test("carries each one exactly as it is published")
    func carriesThemExactly() throws {
        for (name, text) in try Self.published {
            let embedded = try #require(EmbeddedSchemas.byName[name])
            #expect(
                embedded == text.trimmingCharacters(in: .newlines),
                "\(name) differs from what the tool carries: run `mise run schema-embed`"
            )
        }
    }

    /// And each one is a schema this validator can actually check. A schema using a keyword
    /// it does not implement is refused when it is read, so this is where that refusal
    /// surfaces - at the edit, rather than the first time somebody writes a report.
    @Test("carries only schemas it can check")
    func everyOneIsCheckable() throws {
        for (name, text) in try Self.published {
            #expect(throws: Never.self, "\(name) is not a schema this validator can check") {
                try JSONSchema(Data(text.utf8))
            }
        }
    }
}
