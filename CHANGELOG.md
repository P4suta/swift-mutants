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

- The development substrate: strict build settings, the static-analysis gates, and the
  repository invariants they enforce.
- Discovery over swift-syntax with precedence resolved, arid suppression and comment
  pragmas; instrumentation that puts every mutant in one tree behind a runtime guard
  without changing the line count, with an activation proof over both the spliced source
  and the built product.
- `profile` and `operators` now select which operators a run uses. They were read,
  validated and written into the file `init` produces with a comment explaining the tiers,
  and then honoured by nothing at all: setting `profile = "all"` changed no mutant. A rule a
  tier leaves out is reported by `why-skipped` rather than silently absent.
- `extreme` is refused rather than accepted and ignored. Whole-body replacement is not in
  this build, and a setting that is stored and never read gives a project exactly the run
  they would have had without it.
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
