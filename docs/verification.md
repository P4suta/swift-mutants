<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Measurement verification

`mise run check` checks source structure, formatting, source licenses, workflows, secrets, and unit behavior.
`mise run test:integration` exercises real SwiftPM packages, Swift Testing, XCTest, mixed targets, build rejection, timeouts, crashes, cancellation, and an external library consumer.
The release gate checks optimized execution.

## Verdict and score contracts

The pure `TestVerdict.classify` policy uses timeout, trustworthy results, test inventory, and recorded failures.
Timeout takes precedence.
Only trustworthy results with a nonempty matching inventory can become killed or survived.
The inventory includes executed and skipped identities with multiplicities.

`Proofs/Measurement.lean` proves the verdict conditions and score completeness over natural-number counts.
An available score has a positive denominator.
Compiler rejection doesn't affect the fraction.
Timeouts and execution errors prevent a score.

Run the proof command with the toolchain pinned in `Proofs/lean-toolchain`:

```sh
mise run test:proof
```

The command builds with warnings as errors and checks the eight theorems' axiom dependencies.
It replays the model with `leanchecker --fresh` and compares committed CSV fixtures with model-generated values.
The project theorems require no axioms.
Swift tests pass all 24 verdict input classes through the production observation adapter and compare every reason and public outcome with the shared fixture.
All 32 score presence classes and 1,024 count vectors check the public report.
The tests require complete class coverage and reject duplicate fixture rows.
CI requires both the Swift checks and the proof job.

The model doesn't prove the Swift compiler, Foundation XML parsing, process supervision, or floating-point division.
Correspondence tests check the finite policy boundary.
Generated XML tests cover 1,024 documents with independent expected identities and counts.
Real package tests cover the framework output dialects and operating system behavior.
A malformed fixture must fail the proof command even when Lake reuses build artifacts.

## Focused self-mutation

Build the CLI, then measure its critical result and source-range code:

```sh
swift build --product swift-mutants
.build/debug/swift-mutants run \
  --include Sources/SwiftMutants/MutationReport.swift \
  --include Sources/SwiftMutants/TestInvocation.swift \
  --include Sources/SwiftMutants/TestVerdict.swift \
  --include Sources/SwiftMutants/XUnitResults.swift \
  --include Sources/SwiftMutantsCore/SourceSpan.swift \
  --skip RepositoryGateTests --skip IntegrationTests --json
```

Repository gates inspect source text that instrumentation intentionally changes.
Integration tests build packages and belong in a separate verification tier.
The selected unit suites still execute in full for each mutation.
Inspect survivors, execution errors, and timeouts as distinct outcomes.
Add behavior tests for missing invariants, then rerun affected identities with `--mutant`.
Changes to production source require rediscovery because identities include the source digest.
Build events check normal two-build reuse and individual fallback without timing thresholds.
