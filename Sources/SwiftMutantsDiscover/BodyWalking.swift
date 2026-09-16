// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftSyntax

/// Finding declarations whose body could be replaced by a constant.
///
/// Its own file because it is the one rule here that looks at a declaration rather than at
/// an operator, and because what it *cannot* do is half of what it does: a body it passes
/// over is recorded with the reason, and the reasons are the interesting part.
extension CandidateWalker {

    /// Offers a function's body, or says why it could not.
    func offerBody(of node: FunctionDeclSyntax) {
        guard replacesBodies, let body = node.body else { return }
        offer(
            statements: body.statements,
            over: Syntax(body),
            returning: node.signature.returnClause?.type)
    }

    /// Offers a computed property's body.
    ///
    /// Only the shorthand form - `var total: Int { items.reduce(0, +) }` - because a
    /// property with named accessors has a `get` whose body this reaches as its own block,
    /// and offering both would be the same mutant twice.
    ///
    /// Computed properties are where this rule finds the most. They are the declarations
    /// most likely to be run by every test in a suite and asserted on by none of them.
    func offerBody(of node: PatternBindingSyntax) {
        guard replacesBodies, let block = node.accessorBlock,
            case .getter(let statements) = block.accessors
        else { return }
        // The statements as they sit in the file, never a new block built around them. A
        // node put into a freshly made parent is a node in a different tree, and every
        // position inside it is measured from that tree's start rather than from the
        // file's - so a span would name bytes somewhere else entirely. Found by a compile
        // gate, which is the only thing that could have found it: discovery was self
        // consistent and the instrumented file was shredded.
        offer(
            statements: statements,
            over: Syntax(block),
            returning: node.typeAnnotation?.type)
    }

    /// One body, if it is one expression and its type has a value that can be written.
    ///
    /// The two refusals are separate because they are different facts with different
    /// futures. A type nothing can spell is a property of the signature; several statements
    /// is a property of this build, which places no statements.
    private func offer(
        statements: CodeBlockItemListSyntax, over region: Syntax, returning type: TypeSyntax?
    ) {
        // No return type is not an unspellable one: a function that returns nothing has no
        // constant to return, and an empty body is the absence of a value rather than one.
        guard let type else { return }
        guard let constant = BodyValues.constant(for: type) else {
            note(.unspellableReturnType, at: region)
            return
        }
        guard statements.count == 1, let only = statements.first,
            case .expr(let expression) = only.item
        else {
            note(.multiStatementBody, at: region)
            return
        }
        // A body that already is the constant would be replaced by itself: a mutant that
        // cannot fail, and a line in every report that means nothing.
        guard expression.trimmedDescription != constant else { return }
        record(Rules.replaceBody, replacing: Syntax(expression), with: constant)
    }
}
