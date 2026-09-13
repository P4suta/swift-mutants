// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Encoding helpers for tests that pin a document's shape rather than its round trip.
///
/// Keys are sorted so an assertion is about the shape rather than about whatever order
/// the encoder happened to emit today.
enum JSONTestSupport {
    static func canonicalJSON(of value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
