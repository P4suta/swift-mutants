// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

enum RuleSelection {
    static let families: Set<String> = [
        "comparison", "boolean-connective", "boolean-literal", "integer-arithmetic",
        "condition-decision", "concatenation", "statement-deletion",
        "pattern-matching", "error-handling",
    ]
}
