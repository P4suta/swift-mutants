// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
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
        offer(body: body, returning: node.signature.returnClause?.type)
    }

    /// Offers a property's body, in either of the two shapes one can be written.
    ///
    /// Computed properties are where this rule finds the most. They are the declarations
    /// most likely to be run by every test in a suite and asserted on by none of them - and
    /// the ones written with explicit accessors were offered nothing at all, not even a
    /// skip, which is the one answer this tool must never give.
    func offerBody(of node: PatternBindingSyntax) {
        guard replacesBodies, let block = node.accessorBlock else { return }
        offerAccessors(of: block, holding: node.typeAnnotation?.type)
    }

    /// Offers a subscript's accessors, which are a property's in every way that matters
    /// here: a block of accessors, and a written type for what the getter returns.
    func offerBody(of node: SubscriptDeclSyntax) {
        guard replacesBodies, let block = node.accessorBlock else { return }
        offerAccessors(of: block, holding: node.returnClause.type)
    }

    /// An initialiser is a decision rather than an oversight.
    ///
    /// A guard that returned early would leave the instance half-built, which the compiler
    /// refuses outright - so there is no mutant here, and saying so is better than a
    /// declaration that quietly is not in the catalogue.
    func offerBody(of node: InitializerDeclSyntax) {
        guard replacesBodies, let body = node.body, !body.statements.isEmpty else { return }
        note(.unstoppableBody, at: Syntax(body))
    }

    /// One block of accessors, in whichever of the two shapes it was written.
    private func offerAccessors(of block: AccessorBlockSyntax, holding type: TypeSyntax?) {
        guard case .accessors(let written) = block.accessors else {
            guard case .getter(let statements) = block.accessors else { return }
            offerGetter(statements, in: block, holding: type)
            return
        }
        for accessor in written {
            guard let body = accessor.body, !body.statements.isEmpty else { continue }
            switch accessor.accessorSpecifier.tokenKind {
            case .keyword(.get):
                offer(body: body, returning: type)
            // Every one of these returns nothing, and a body whose whole purpose is a side
            // effect makes "does anything notice when it stops happening" the only question
            // worth asking about it.
            case .keyword(.set), .keyword(.willSet), .keyword(.didSet):
                offer(body: body, returning: nil)
            // `_read` and `_modify` are coroutines: returning before yielding is not a
            // mutant, it is a trap. Named rather than passed over in silence.
            default:
                note(.unstoppableBody, at: Syntax(body))
            }
        }
    }

    private func offerGetter(
        _ statements: CodeBlockItemListSyntax,
        in block: AccessorBlockSyntax,
        holding type: TypeSyntax?
    ) {
        // The statements as they sit in the file, never a new block built around them. A
        // node put into a freshly made parent is a node in a different tree, and every
        // position inside it is measured from that tree's start rather than from the
        // file's - so a span would name bytes somewhere else entirely. Found by a compile
        // gate, which is the only thing that could have found it: discovery was self
        // consistent and the instrumented file was shredded.
        guard let interior = Self.interior(from: block.leftBrace, to: block.rightBrace) else {
            return
        }
        offer(
            statements: statements,
            interior: interior,
            over: Syntax(block),
            returning: type)
    }

    /// The bytes between a block's braces, which is what a statement guard covers.
    ///
    /// From just after `{` to just before `}`. The guard is spliced at the start of it, so
    /// it lands on the brace's own line and every line number below is unchanged - which is
    /// what the coverage a run reads back afterwards rests on. Never the braces themselves:
    /// a guard in front of `{` would sit beside the signature.
    private static func interior(
        from left: TokenSyntax, to right: TokenSyntax
    ) -> SourceSpan? {
        SourceSpan(start: left.endPosition.utf8Offset, end: right.position.utf8Offset)
    }

    /// One function body, which can take a guard of either shape.
    private func offer(body: CodeBlockSyntax, returning type: TypeSyntax?) {
        guard let interior = Self.interior(from: body.leftBrace, to: body.rightBrace) else {
            return
        }
        offer(
            statements: body.statements,
            interior: interior,
            over: Syntax(body),
            returning: type)
    }

    /// One body, if it is one expression and its type has a value that can be written.
    ///
    /// The two refusals are separate because they are different facts with different
    /// futures. A type nothing can spell is a property of the signature; several statements
    /// is a property of this build, which places no statements.
    private func offer(
        statements: CodeBlockItemListSyntax,
        interior: SourceSpan,
        over region: Syntax,
        returning type: TypeSyntax?
    ) {
        // An empty body has nothing to replace: doing nothing instead of nothing is a
        // mutant that cannot fail, and a line in every report that means nothing.
        guard !statements.isEmpty else { return }

        // A body that returns nothing still has a mutant, and a good one: does anything
        // notice when this stops doing its work? There is no value to return, so it can
        // only be said as a statement - which is why this waited for the second form.
        guard let type, !BodyValues.returnsNothing(type) else {
            record(Rules.stopBody, inside: interior, of: region, doing: "return")
            return
        }
        guard let constant = BodyValues.constant(for: type) else {
            note(.unspellableReturnType, at: region)
            return
        }
        // One expression is an expression, so it takes the guard that disturbs nothing
        // around it. Preferred wherever it applies: a ternary is one type-checking problem
        // and a statement in front of a body is a change to the body's shape.
        if statements.count == 1, let only = statements.first,
            case .expr(let expression) = only.item
        {
            // A body that already is the constant would be replaced by itself.
            guard expression.trimmedDescription != constant else { return }
            record(Rules.replaceBody, replacing: Syntax(expression), with: constant)
            return
        }
        record(Rules.stopBody, inside: interior, of: region, doing: "return \(constant)")
    }
}
