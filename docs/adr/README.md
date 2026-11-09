<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Architecture decision records

Each record explains a consequential choice, its constraints, alternatives, costs, and confirmation.

[Byte spans](0001-mutants-are-anchored-to-byte-spans.md) anchor mutation identities to UTF-8 source bytes.
[Expression guards](0002-expression-guards-are-the-default-form.md) define the default instrumentation form.

Historical records describe the [SwiftPM testing helper](0003-tests-are-launched-through-the-swiftpm-helper.md), [module validation](0004-validation-asks-each-module-separately.md), [cached answers](0005-an-answer-may-be-remembered-while-what-it-rests-on-is-unchanged.md), and the [Xcode execution path](0006-the-xcode-path-goes-through-the-xctestrun.md).

[Optimized execution](0007-the-shipped-configuration-gets-its-own-tier.md) requires its own release tier.
[Guard placement](0008-a-guard-wraps-an-expression-and-nothing-else.md) distinguishes expressions from declarations.
[Build counts](0009-there-is-no-benchmark-gate.md) verify reuse without a benchmark gate.

[Measure package mutations through a library](expose-source-mutations-through-a-library.md) defines the public measurement API and replaces the helper, validation, caching, and Xcode execution paths described in the historical records.

[Trust complete test results before scoring](trust-complete-test-results.md) defines result evidence, supported XML counts, and the boundary of the measurement proofs.

[Keep compatible instrumentation after a guard failure](retain-compatible-instrumentation.md) limits individual builds to candidates without usable guards.
