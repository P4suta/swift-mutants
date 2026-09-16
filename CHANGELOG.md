<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Equivalence proving finds equivalent mutants at all. It never had: the first compile
  into a module cache it has to build exits 0 and prints no SIL whatsoever, so the
  original's fingerprint was the digest of an empty string and no mutant ever equalled it.
  One compile now fills the cache and its answer is thrown away, and a compile that
  printed nothing is refused as a fingerprint rather than hashed.
- A suppression comment may name any family the catalogue has. The list a comment was
  checked against was written out by hand beside the rules and was missing
  `concatenation`, so a project that disabled their own family was told it was a typo and
  the comment they believed had dealt with a mutant silenced nothing. It is read off the
  rules now, so a family added later is nameable the day it is added.
- The development substrate: strict build settings, the static-analysis gates, and the
  repository invariants they enforce.
- Discovery over swift-syntax with precedence resolved, arid suppression and comment
  pragmas; instrumentation that puts every mutant in one tree behind a runtime guard
  without changing the line count, with an activation proof over both the spliced source
  and the built product.
- A pattern's `where` clause made always and never to hold, and a `try?` made to fail
  every time. In `balanced`.
- One mutant per edit: two rules that arrive at the same bytes with the same replacement
  now yield one candidate rather than two.
- Nightly and weekly workflows: the Xcode path, three sanitizers, the dogfood run, and
  real packages at the revisions this repository already pins.
- The `all` tier has something in it: an integer literal one either side of what was
  written, and a unary minus taken away. It selected exactly what `strong` did before.
- A statement that does not run: the largest family there is, and the one with the best
  record in the literature. In `balanced`.
- Validation's fallback compiler now lowers to SIL rather than only type-checking, which is
  what the module path beside it already did. `-typecheck` does not report a missing return,
  so a mutant that guarded away a function's only return passed validation and failed the
  real build.
- The ends of a collection, swapped for each other: `first`/`last`, `min`/`max`,
  `prefix`/`suffix` and four more pairs. In `strong`.
- Two families Swift has that other languages do not: a range that reaches one element
  further than it was written to, and both mutants a coalescing operator has. In `strong`.
- `extreme` replaces a declaration's body with a constant, which asks whether it is tested
  at all rather than whether one operator is right. Both shapes a body can take: a ternary
  where it is one expression, and a statement in front of it where it is not — which is
  also what lets a function that returns nothing be measured, there being no value to put
  in a ternary's branches. Measured on this repository: 482 bodies offered.
- `strict`, `minimum_score`, `formats`, `directory`, `high` and `low` now do what they
  say, and `baseline_runs` measures the baseline that many times: a suite that disagrees
  with itself is named as flaky rather than reported as this tool's instrumentation being
  broken. `test.command` and `test.memory` are refused, the second on a measurement — this
  platform reports `unlimited` under `ulimit -v` and lets a process take four gigabytes.
- `profile` and `operators` now select which operators a run uses. They were read,
  validated and written into the file `init` produces with a comment explaining the tiers,
  and then honoured by nothing at all: setting `profile = "all"` changed no mutant. A rule a
  tier leaves out is reported by `why-skipped` rather than silently absent.
- A run says which of your tests stepped aside in the copy it happens in: swift-testing
  reports a disabled suite on the event stream, and a skipped test used to be
  indistinguishable from one that ran and passed — which made anything only those tests
  cover a permanent survivor nobody could write a test for.
- A scripted toolchain, a recording process runner, a trace with a bounded always-on ring,
  a diagnostics bundle, a strict TOML configuration reader, and a disposable snapshot.
- The pure core: `SourceSpan`, `SHA256`, `Digest`, `DigestBuilder`,
  `WorkspaceRelativePath`, `RuleIdentifier`, `MutantIdentity`, `Mutant`, `Catalog`,
  `Outcome`, `MutationScore`, `Glob`, `GlobSet` and `IntervalForest` — none of which
  opens a file, starts a process or reads a clock.

### Changed

- `reuse lint` runs from the pinned tool set like every other gate, rather than being
  fetched at run time by a tool that is not pinned at all, and reports a file it objects to
  by name rather than only failing.
- A compile whose output did not all fit is refused as a fingerprint. Output is captured
  up to a limit and a module's lowered form is easily larger, so two mutants differing
  past the limit had the same head - and hashing the head reports a real survivor as a
  mutant nothing could ever catch, which takes a genuine hole in somebody's tests out of
  their score. A process outcome now says how many bytes there really were.
