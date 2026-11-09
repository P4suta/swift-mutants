---
date: 2026-11-10
---

<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Trust complete test results before scoring

**Status:** proposed.

## Context

A recorded failure alone doesn't establish that the selected suite completed.
The [Swift Testing XML recorder](https://github.com/swiftlang/swift-testing/blob/swift-6.3-RELEASE/Sources/Testing/Events/Recorder/Event.JUnitXMLRecorder.swift) counts started tests without including skipped tests.

## Decision

Require trustworthy, matching test inventories before reporting killed or survived.
Use structured identities, XML parent checks, and explicit inconclusive diagnostics.
Support counts of all cases or started cases.

Lean checks the verdict and score model.
Swift tests check every finite observation class through a shared fixture.
Boundary tests cover XML and processes.
The proof covers the model.

## Alternatives

Any failure as killed tolerates incomplete suites.
[Stryker](https://stryker-mutator.io/docs/General/faq/) counts timeout as detected.
Both conflict with the measurement contract.

## Consequences

A changed inventory yields errored even after an assertion failure.
Keep the public API.
Reconsider the observation classes when SwiftPM changes its result protocol.

## Confirmation

Check kernel proofs and their axioms, every observation class, skipped tests, malformed XML, and self-mutation survivors.
