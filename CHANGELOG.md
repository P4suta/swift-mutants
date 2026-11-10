<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Changelog

## Unreleased

Require matching executed and skipped test inventories before reporting `killed`.
Validate XML parent structure and distinguish test identities without delimiter collisions.
Support Swift Testing counts that exclude skipped cases.
Keep compatible instrumentation when another guard fails to compile.
Check verdict and score contracts with Lean proofs and exhaustive Swift correspondence fixtures.
Return `nil` for source-range shifts that overflow integer offsets.
Find activation tokens beyond retained symbol diagnostics while keeping output memory bounded.
Distinguish SwiftPM abnormal-exit diagnostics from quoted text in verbose test arguments.
Keep complete Swift Testing failures measurable beyond diagnostic retention while detecting late crashes.
Identify abnormal test exits before retained diagnostic text.
Pass subprocess environments through typed strings so extra bytes can't corrupt mutation activation.
Ignore quoted XCTest completion text and preserve completion evidence for skipped XCTest cases.
Reconcile explicit skipped XML cases with XCTest completion records and duplicate test identities.

Expose source discovery, UTF-8 editing, package listing, and complete measurement through `import SwiftMutants`.
The CLI uses the public library and offers `list` and `run`.

Measure Swift Testing, XCTest, and mixed targets with public SwiftPM commands and xUnit results.
Check the original baseline and three inactive baselines, run each selected mutation with the complete suite, and fall back to individual edits for instrumentation build failures.
Cancellation and CLI signals stop owned processes across process groups before returning.

Score only kills divided by kills plus survivors.
Timeouts, errors, and an empty denominator leave the final score absent.
Measurement JSON uses schema version 3.

Use the fixed nine balanced mutation families.
Remove TOML configuration, caching, coverage selection, simultaneous mutants, sharding, differential runs, compiler equivalence, custom mutations, expected survivors, the terminal browser, history commands, and report projections.
Measurement preserves existing report files.
