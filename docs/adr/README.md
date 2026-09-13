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
