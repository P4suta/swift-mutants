<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# swift-mutants

Mutation testing for Swift that is fast enough to leave switched on.

swift-mutants instruments every compilable mutant **once** into a disposable snapshot of
your package, then activates one mutant per test process through an environment variable.
Your working tree is never modified, and the toolchain builds essentially once instead of
once per mutant.

## Status: the core exists, the engine does not

This repository is being built from the ground up, gate first, and every phase ships its
own diagnostics in the same change that introduces it.

What exists today is the development substrate and the pure core: the strict build
settings, the static-analysis gates, the repository invariants they enforce, and the
values everything else will be built out of —

| | |
| --- | --- |
| `SourceSpan` | a half-open range of UTF-8 byte offsets |
| `SHA256`, `Digest`, `DigestBuilder` | content addressing, length-prefixed so fields cannot run together |
| `WorkspaceRelativePath` | a path that refuses to be absolute |
| `RuleIdentifier` | `add-to-sub@1`, with the version inside the identity |
| `MutantIdentity`, `Mutant`, `Catalog` | what a mutant is called, and what a run found |
| `Outcome`, `MutationScore` | what became of a mutant, and what that scores |
| `Glob`, `GlobSet` | which files a run mutates |
| `IntervalForest` | how a file's mutants nest before any is spliced |

Nothing mutates anything yet. Do not describe swift-mutants as usable: nothing is
published, tagged, or released.

## Requirements

- Swift 6.3 or newer
- macOS 15 or newer
- [mise](https://mise.jdx.dev), which pins every tool the gates depend on

## Working on this repository

```console
mise trust
mise install
./scripts/doctor.sh    # can this machine develop swift-mutants?
mise run check         # every gate, then the unit tier
mise run watch         # the TDD inner loop
```

`mise run check` is the whole quality bar in one command, and `lefthook` runs the fast
half of it before each commit and all of it before each push.

## How this is built

Development is test-driven without exception, and the diagnostic substrate is built before
the thing it diagnoses. Both rules are load-bearing rather than decorative: a mutation
testing tool cannot demonstrate its own correctness by inspection — nobody can look at a
mutation score and see whether it is right — so the tests are the specification, and the
trace is how a disagreement gets settled.

A few invariants are enforced by gates rather than by review, because they are the kind of
mistake review does not catch:

| Gate | What it prevents |
| --- | --- |
| `MutantAnchorGateTests` | Anchoring a mutation site on a syntax-tree node identity |
| `PurityGateTests` | The pure core reaching for a file, a process, or a clock |
| `TestTierGateTests` | The inner loop quietly growing a toolchain dependency |
| `UpcomingFeatureLedgerTests` | The manifest drifting from what the toolchain offers |
| `ProvenanceGateTests` | A file without an SPDX header, or text that is not English |
| `rules/ast-grep/` | `Foundation.Process`, `ProcessInfo.environment`, per-node `SourceLocationConverter` |

## Sibling projects

swift-mutants is the fifth in a family of mutation testing tools that share one
architecture — read-only workspaces, disposable snapshots, instrument-once schemata,
stable content-addressed identities, strict configuration, and honest reports:

- [rust-mutants / njutest](https://github.com/P4suta/njutest) — Rust and Cargo
- [go-mutants](https://github.com/P4suta/go-mutants) — Go modules
- [gleam-mutants](https://github.com/P4suta/gleam-mutants) — Gleam, across Erlang, Node.js, Deno and Bun
- [ocaml-mutants](https://github.com/P4suta/ocaml-mutants) — OCaml and Dune

## Licence

Licensed under either the MIT License or the Apache License 2.0, at your option. See
[LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE). The repository is
REUSE-compliant.
