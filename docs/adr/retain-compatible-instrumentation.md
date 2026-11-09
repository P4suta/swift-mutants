---
date: 2026-11-10
---

<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Keep compatible instrumentation after a guard failure

**Status:** proposed.

## Context

A ternary guard can fail typechecking although an individual edit compiles.
Discarding every guard then requires a build for every mutation.
[Muter's schemata](https://github.com/muter-mutation-testing/muter#mutant-schemata) expose the same compilation boundary.

## Decision

On a guard compilation failure, bisect candidates deterministically while retaining compilable groups.
Rebuild and verify activation tokens for the retained set before its inactive baselines.
Measure guarded candidates first, then individual edits, and return results in discovery order.
Only an individual edit can receive compiler rejection.

## Alternatives

Global fallback is simpler but rebuilds every compatible candidate.
Compiler diagnostic attribution avoids probes but depends on unstable diagnostics.

## Consequences

Normal packages still require two builds.
Incompatible groups require extra probes.
Startup failures and deadlines stop preparation.
Reconsider if probing dominates real runs.

## Confirmation

Compare mixed compatible and incompatible candidates with individual measurement.
Check build events, result order, source preservation, and the two-build normal path.
