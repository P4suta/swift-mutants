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

## Status: it measures a package; it does not yet report one

Built from the ground up, gate first, with every phase shipping its own diagnostics in the
same change that introduces it. `swift-mutants run` works end to end on a real package:

```console
$ swift-mutants run
copying the package
reading the sources
instrumenting 5 mutants across 1 files
asking the compiler which ones it will accept
proving every mutant is in the tree
building the tests, once
running the tests with nothing awake
running 5 mutants

survived:
  Sources/Cart/Cart.swift  4b4874975176fe2463e9  and-keep-lhs

4 killed  1 survived  0 rejected  0 timed out  0 errored
score 80.00%  of covered code 80.00%
```

That survivor is `total >= threshold && isMember` with `&& isMember` dropped. It survives
because no test passes a non-member — a real hole, found by reading nothing.

What works today, proven by tests that compile and run real code:

| | |
| --- | --- |
| **Pure core** | byte spans, SHA-256, content-addressed mutant identities, catalogue, score, glob, interval forest |
| **Observability** | always-on trace with a bounded ring, one choke point that records every subprocess, deterministic console renderer, diagnostics bundle |
| **A scripted toolchain** | a `swift` and an `xcodebuild` that hang, print garbage or leave a red baseline on demand, so the unit tier can test what happens when a real one misbehaves |
| **Configuration** | a TOML reader that refuses an unknown key with the line it was written on |
| **Snapshot** | a disposable copy that refuses links and special files, and a second digest that notices a test writing into the tree |
| **Discovery** | comparisons, connectives and their operand prunes, boolean literals, arithmetic, compound assignment and bitwise — with precedence resolved, arid suppression, and comment pragmas |
| **Instrumentation** | every mutant in one tree behind a runtime guard, the line count unchanged, and an activation proof |
| **Validation** | one typecheck names every mutant the compiler refuses, in its own words; halving is the fallback, not the mechanism |
| **Execution** | one build, one process per mutant, the event stream watched live so a mutant costs the time until a test notices rather than the time the suite takes |

The instrumented file is known to compile, to behave exactly as the original when nothing
is activated, to change exactly one thing when one mutant is woken, and to survive `-O`.

What is missing is the report: `run --json`, the Stryker projection, the offline HTML,
SARIF, coverage-driven test selection, the outcome cache, and the Xcode path. **Nothing is
published, tagged, or released, and the command tree will change.**

## Trying it

```sh
swift build -c release
.build/release/swift-mutants doctor        # can this machine run it
.build/release/swift-mutants list          # what would it measure, without measuring
.build/release/swift-mutants run           # measure it
.build/release/swift-mutants run -- --skip SlowTests   # your arguments, verbatim
```

Arguments after `--` go to your tests exactly as written and are never interpreted. They
are a scope as well as a setting: narrowing the suite narrows what the score is about.

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
