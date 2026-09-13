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
- The pure core: `SourceSpan`, `SHA256`, `Digest`, `DigestBuilder`,
  `WorkspaceRelativePath`, `RuleIdentifier`, `MutantIdentity`, `Mutant`, `Catalog`,
  `Outcome`, `MutationScore`, `Glob`, `GlobSet` and `IntervalForest` — none of which
  opens a file, starts a process or reads a clock.
