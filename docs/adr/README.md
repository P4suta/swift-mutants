<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Architecture decision records

One record per decision that would otherwise be re-litigated. Each states the decision,
what forced it, and what it costs — including the decisions inherited from the sibling
projects and, where swift-mutants departs from them, why.

| # | Decision |
| --- | --- |
| [0001](0001-mutants-are-anchored-to-byte-spans.md) | A mutant is anchored to a UTF-8 byte span, never to a syntax node identity |
| [0002](0002-expression-guards-are-the-default-form.md) | Expression-level ternary guards are the default instrumentation form |
| [0003](0003-tests-are-launched-through-the-swiftpm-helper.md) | Tests are launched through the SwiftPM testing helper, not through `swift test` |
| [0004](0004-validation-asks-each-module-separately.md) | Validation asks each module separately, using SwiftPM's own plan |
| [0005](0005-an-answer-may-be-remembered-while-what-it-rests-on-is-unchanged.md) | An answer may be remembered while everything it rests on is unchanged |
| [0006](0006-the-xcode-path-goes-through-the-xctestrun.md) | The Xcode path wakes a mutant through the `.xctestrun`, beside the original |
| [0007](0007-the-shipped-configuration-gets-its-own-tier.md) | The shipped configuration gets its own tier, built from nothing |
| [0008](0008-a-guard-wraps-an-expression-and-nothing-else.md) | A guard wraps an expression, and a declaration needs a statement in front of it |
| [0009](0009-there-is-no-benchmark-gate.md) | There is no benchmark gate: a wall clock is not a property of the program |
