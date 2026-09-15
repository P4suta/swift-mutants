// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsValidate

/// What a run says when one compile did not name every refusal.
///
/// Its own file because it is the longest thing this tool has to explain and the only
/// one whose whole value is the explanation: halving finds the same answer either way,
/// at one compile per narrowing instead of one in total, so what a reader needs is not
/// the outcome but why the fast path did not take.
extension Narration {

    /// Whose failure it is that one compile did not name every refusal.
    ///
    /// Two different pieces of news, and they were one sentence. Diagnostics read and none
    /// of them at a mutant is a fact about the program: a `missing return` reported at a
    /// closing brace nowhere near the mutant that removed the return, an error inside a
    /// macro buffer, a linker. Nothing read *at all* out of a compile that failed is this
    /// tool's own parser not recognising the shape - which is not hypothetical, because
    /// when SwiftPM began emitting colour every diagnostic parsed as nothing and every
    /// package alike fell into halving.
    ///
    /// The count rather than only the first, because "one stray error" and "forty of them,
    /// none of which are mine" are different situations whose first line looks the same.
    static func whyTheFastPathDidNotTake(
        read: Int, unplaceable: CompilerDiagnostic?
    ) -> String {
        guard read > 0 else {
            return """

                  the compiler failed and this could read none of what it wrote as a \
                diagnostic, which is a defect in this tool rather than in your package. \
                Halving will still find the refusals; it will take one compile per \
                narrowing rather than one in total.
                """
        }
        return "\n  it read \(read) and placed none of them at a mutant"
            + (unplaceable.map {
                "\n  the first: \($0.file):\($0.position): \($0.message)"
                    + ($0.isUnaffordable ? "\n" + Self.unaffordable : "")
            } ?? "")
    }

    /// What to say when the compiler ran out of budget rather than refusing anything.
    ///
    /// Different news from a refusal, and the only one of the two a reader can act on. The
    /// expression type-checks fine as written and tips over once guards wrap its
    /// subexpressions, which means it was already close to the edge - so this is a finding
    /// about their code that happens to have been made by a mutation tool.
    ///
    /// Said plainly because it otherwise reads exactly like a mutant that was not valid
    /// Swift, and a reader would take it as this tool's problem rather than theirs.
    static let unaffordable = """
          that is not a mutant it refused: the expression type-checks as you wrote it and \
        becomes too expensive once a guard is inside it. Breaking it into statements \
        usually helps, and is usually worth doing anyway.
        """
}
