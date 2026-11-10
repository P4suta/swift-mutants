---
date: 2026-11-10
---

<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Check completion beyond retained diagnostics

**Status:** proposed.

## Context

Self-mutation produced complete Swift Testing XML but exceeded the diagnostic limit.
Rejecting every truncated log hides recorded failures.
Accepting XML alone could hide a later process crash.

## Decision

Recognize SwiftPM abnormal-exit lines while draining both streams.
Keep matching state independent of diagnostic retention.
Require complete XML and consistent process status.
Swift Testing failures can remain trustworthy after diagnostic truncation.
XCTest still requires an untruncated completion transcript, including skipped cases.
Use verbose output when the original baseline observes XCTest.

The [Swift Testing recorder](https://github.com/swiftlang/swift-testing/blob/swift-6.3-RELEASE/Sources/Testing/Events/Recorder/Event.JUnitXMLRecorder.swift) closes XML at run completion.
The [SwiftPM implementation](https://github.com/swiftlang/swift-package-manager/blob/swift-6.3-RELEASE/Sources/Commands/SwiftTestCommand.swift) supplies process diagnostics and XCTest completion output.

## Alternatives

Unbounded capture risks memory exhaustion.
Rejecting all truncated logs prevents measurement of otherwise complete failures.

## Consequences

Matching memory depends on patterns and chunks.
Unknown XML and abnormal exits remain inconclusive.
Reconsider when framework completion or SwiftPM diagnostics change.

## Confirmation

Check fragmented lines, large valid failures, late crashes beyond retention, and real framework fixtures.
