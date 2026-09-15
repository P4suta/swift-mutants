// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore

/// Putting a mutated copy of a site onto one line.
///
/// Its own file because it is the part of splicing with a reason of its own: the
/// original copy beside it in the guard keeps every newline the file had, so a copy that
/// kept its own would add them - and every line number in an instrumented file has to
/// equal the original's, or the coverage a run reads back afterwards is about different
/// lines than the ones it measured.
extension Instrument {

    /// A run of the file's bytes with any comment in it left out.
    ///
    /// The newline that ended a comment is not part of it - swift-syntax counts the two
    /// apart - so it stays, and becomes the space that keeps the tokens either side of it
    /// from running together.
    static func bytes(
        _ bytes: [UInt8], from start: Int, to end: Int, less comments: [SourceSpan]
    ) -> String {
        let inside = comments.filter { $0.start >= start && $0.end <= end }
        guard !inside.isEmpty else {
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }
        var text = ""
        var cursor = start
        for comment in inside.sorted() where comment.start >= cursor {
            text += String(decoding: bytes[cursor..<comment.start], as: UTF8.self)
            cursor = comment.end
        }
        text += String(decoding: bytes[cursor..<end], as: UTF8.self)
        return text
    }
}
