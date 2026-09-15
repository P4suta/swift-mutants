// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftSyntax

/// Where a file's line comments and multi-line strings are.
///
/// Both are about one thing: the mutated copy of a site is put on one line. The original
/// copy beside it keeps every newline the file had, so a copy that kept its own would add
/// them - and every line number in an instrumented file has to equal the original's, or the
/// coverage a run reads back afterwards is about different lines than the ones it measured.
///
/// A line comment runs to the end of its line, so joining the lines would put the rest of
/// the guard inside the comment. It comes out of the copy instead, which costs nothing: a
/// comment has no meaning to a compiler, and the original copy beside it keeps every byte.
/// This was a refusal until a package with 87 commented expressions across 32 files had
/// four runs stop on one site each, after the whole instrument-and-validate pass.
///
/// A multi-line string cannot come out and cannot be joined - its newlines are its content,
/// not its layout - so a site holding one is passed over with a name.
///
/// Both have to be read from the tree rather than from the bytes. `//` inside a string
/// literal is not a comment, and `"""` inside a comment is not a string; the refusal this
/// replaced matched two characters and could tell neither apart.
struct SourceScan {

    /// Every line comment in the file, in the bytes the user wrote.
    let lineComments: [SourceSpan]

    /// Where each multi-line string literal begins.
    ///
    /// The opening quote alone is enough to place one: a site either contains the whole
    /// literal, and so contains its opening quote, or it is *inside* the literal - which is
    /// a candidate in an interpolation, and that flattens perfectly well because the
    /// literal around it is not part of the copy.
    let multilineStrings: [SourceSpan]

    init(_ tree: Syntax) {
        var comments: [SourceSpan] = []
        var strings: [SourceSpan] = []

        for token in tree.tokens(viewMode: .sourceAccurate) {
            Self.comments(in: token.leadingTrivia, from: token.position.utf8Offset, into: &comments)
            Self.comments(
                in: token.trailingTrivia,
                from: token.endPositionBeforeTrailingTrivia.utf8Offset,
                into: &comments)

            guard token.tokenKind == .multilineStringQuote,
                let quote = SourceSpan(
                    start: token.positionAfterSkippingLeadingTrivia.utf8Offset,
                    end: token.endPositionBeforeTrailingTrivia.utf8Offset)
            else { continue }
            strings.append(quote)
        }

        self.lineComments = comments
        self.multilineStrings = strings
    }

    /// The line comments in one run of trivia, at their place in the file.
    private static func comments(
        in trivia: Trivia, from start: Int, into found: inout [SourceSpan]
    ) {
        var offset = start
        for piece in trivia {
            let length = piece.sourceLength.utf8Length
            switch piece {
            case .lineComment, .docLineComment:
                if let span = SourceSpan(start: offset, end: offset + length) {
                    found.append(span)
                }
            default:
                break
            }
            offset += length
        }
    }

    /// Whether a site can be put on one line at all.
    ///
    /// It cannot when a multi-line string *starts* inside it. A candidate inside one - in
    /// an interpolation - is not affected: the literal around it stays in the file, and
    /// only the interpolated expression is copied.
    func holdsAMultilineString(_ site: SourceSpan) -> Bool {
        multilineStrings.contains { site.start <= $0.start && $0.end <= site.end }
    }
}

extension SyntaxProtocol {

    /// This node's text, with any line comment in it left out.
    ///
    /// What a mutated copy is built from. The copy is put on one line, and a line comment
    /// runs to the end of its line, so a copy that kept one would have the rest of the
    /// guard inside it - the closing parenthesis included, which is a file that does not
    /// parse rather than a mutant that does not compile.
    ///
    /// Taking it out costs nothing. A comment has no meaning to a compiler, and the
    /// original copy beside it in the guard keeps every byte the file had, so a person
    /// reading the instrumented tree still sees their own comment where they wrote it.
    ///
    /// Built from the tokens rather than from the text, for the same reason discovery does
    /// this at all: `//` inside a string literal is not a comment, and nothing looking at
    /// characters can tell the two apart.
    var flattenableDescription: String {
        var text = ""
        for token in trimmed.tokens(viewMode: .sourceAccurate) {
            text += Self.withoutLineComments(token.leadingTrivia)
            text += token.text
            text += Self.withoutLineComments(token.trailingTrivia)
        }
        return text
    }

    private static func withoutLineComments(_ trivia: Trivia) -> String {
        var text = ""
        for piece in trivia {
            switch piece {
            case .lineComment, .docLineComment:
                continue
            default:
                piece.write(to: &text)
            }
        }
        return text
    }
}
