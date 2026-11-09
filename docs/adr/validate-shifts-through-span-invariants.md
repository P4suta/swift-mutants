---
date: 2026-11-10
---

<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Validate shifts through span invariants

**Status:** proposed.

## Context

Self-mutation exposed redundant overflow checks and missing strict-order assertions.
Spans already require nonnegative, ordered offsets.

## Decision

Use overflow addition and validate the resulting span through its initializer.
A nonnegative offset plus a signed distance can't underflow.
Positive overflow produces a negative signed result, which span validation rejects.
Swift defines the [overflow operators](https://github.com/swiftlang/swift-book/blob/main/TSPL.docc/LanguageGuide/AdvancedOperators.md#overflow-operators).
Delegate lexicographic comparison to tuple comparison.

## Alternatives

Separate overflow flags duplicate span validation.
Unchecked addition traps before validation.

## Consequences

Keep the public behavior and nonnegative-offset invariant.
Reconsider if spans permit negative offsets or the integer representation changes.

## Confirmation

Compare shifts with an Int128 oracle at signed boundaries.
Check interval operations with independent byte and boundary sets.
Check strict-order laws and repeat the surviving mutation families.
