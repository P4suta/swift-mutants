<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Changelog

## Unreleased

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
