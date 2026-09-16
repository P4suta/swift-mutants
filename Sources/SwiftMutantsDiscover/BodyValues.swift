// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftSyntax

/// The value a declaration could return instead of doing its work.
///
/// Replacing a body with a constant asks a different question from every other rule here.
/// The others ask whether one operator is right; this asks whether the declaration is
/// tested at all - whether anything notices when its body stops doing anything. The
/// literature is unusually clear that the answer is often no: across the projects surveyed
/// for pseudo-tested methods, a median of one in ten was covered by tests that asserted
/// nothing whatever about it.
///
/// Read from the return type as it is *written*, not as it is resolved. A named type this
/// does not recognise could be anything, including a type with no value anybody can spell,
/// so it is passed over rather than guessed at - and passed over by name, so a reader can
/// see what the rule could not do.
enum BodyValues {

    /// What to put in place of a body returning this type, or nothing for a type this
    /// cannot spell a value for.
    ///
    /// Optional first, and before the named types: `Int?` is an optional whose value is
    /// `nil`, and reading the `Int` inside it would replace a body that may return nothing
    /// with one that returns zero - a different and much weaker mutant.
    static func constant(for type: TypeSyntax) -> String? {
        if type.is(OptionalTypeSyntax.self)
            || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
        {
            return "nil"
        }
        if type.is(ArrayTypeSyntax.self) { return "[]" }
        if type.is(DictionaryTypeSyntax.self) { return "[:]" }
        guard let named = type.as(IdentifierTypeSyntax.self) else { return nil }
        let name = named.name.text
        if let spelled = Self.byName[name] { return spelled }
        // The spelled-out generic forms of the shapes above. `Set` has no literal of its
        // own, and an empty array literal is what Swift builds one from.
        switch name {
        case "Array", "Set", "ContiguousArray": return "[]"
        case "Dictionary": return "[:]"
        default: return nil
        }
    }

    /// The types whose empty value is a literal, by the name a signature writes.
    ///
    /// `false` rather than `true` for `Bool`, and `0` rather than `1` for a number: the
    /// weaker-looking constant is the better mutant here, because a body that is only ever
    /// checked for being *something* is exactly the shape this rule exists to find.
    private static let byName: [String: String] = {
        var table: [String: String] = [
            "Bool": "false",
            "String": "\"\"",
            "Substring": "\"\"",
            "Character": "\" \"",
            "Double": "0", "Float": "0", "Float16": "0", "Float80": "0", "CGFloat": "0",
        ]
        for width in ["", "8", "16", "32", "64"] {
            table["Int\(width)"] = "0"
            table["UInt\(width)"] = "0"
        }
        return table
    }()
}
