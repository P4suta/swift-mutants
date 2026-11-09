---
date: 2026-11-10
---

<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Measure package mutations through a library

**Status:** proposed.

## Context

Consumers need measurement through `import SwiftMutants`.
Swift Testing and XCTest [coexist](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project).

## Decision

Keep UTF-8 edits and identities, with nine balanced families.
Expose listing, measurement, reports, and progress through the library.
The CLI calls the public API and owns signal handlers.
Cancellation stops tracked descendants across process groups before returning.

Build snapshots through public SwiftPM commands.
Run `swift test --skip-build --parallel --num-workers 1` with [framework-specific XML](https://github.com/swiftlang/swift-package-manager/blob/swift-6.3-RELEASE/Sources/Commands/SwiftTestCommand.swift#L444-L477).
Require matching nonempty original and three inactive baselines.
Measure mutants serially, falling back to individual edits for guard build failures.
Score `killed / (killed + survived)`.
Timeout, error, or an empty denominator yields `nil`.

## Alternatives

CLI-only measurement forces output parsing.
Individual builds avoid guard interactions but rebuild every mutant.

## Consequences

Remove configuration, caches, coverage selection, parallel scheduling, history, and report projections.
Preserve report files and version the measurement JSON.
Reject unsupported package boundaries.
Reconsider when consumers request Xcode or external fixtures.

## Confirmation

Verify framework fixtures, failures, UTF-8 preservation, build reuse, cancellation, and an external consumer.
Run `mise run check` and `mise run test:integration`.
Optimized builds stay in the release gate.
