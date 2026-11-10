---
date: 2026-11-10
---

<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Match activation tokens while draining symbols

**Status:** proposed.

## Context

Self-mutation stopped because SwiftSyntax's symbol listing exceeded the runner's diagnostic limit.
An output prefix can't establish whether later symbols contain an activation token.

## Decision

Search bytes while draining stdout, independently of diagnostic retention.
Keep only the overlap needed to match tokens across chunks.
Check defined symbols and collect matching tokens across built products.
Still require normal process completion before accepting matches.

## Alternatives

Increasing the diagnostic limit only moves the failure threshold.
Reading symbol tables directly adds a Mach-O parser.
An external filtering pipeline complicates process ownership.

## Consequences

Symbol volume no longer determines retained diagnostic memory.
Matching memory depends on token lengths and chunk size.
Test output keeps its truncation checks.
Reconsider when the symbol tool or runtime naming changes.

## Confirmation

Test every chunk split, invalid UTF-8, overlapping needles, and matches beyond the diagnostic limit.
Repeat the real self-mutation build that exposed the failure.
