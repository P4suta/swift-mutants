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

## Status: it measures a package, and reports one

Built from the ground up, gate first, with every phase shipping its own diagnostics in the
same change that introduces it. Measuring this repository with itself:

```console
$ swift-mutants run
copying the package
reading the sources
building your package as you wrote it, once
instrumenting 751 mutants across 84 files
asking the compiler about all 751 mutants at once
  the compiler refused 24
  asking again, 727 left
  the compiler refused 1
  asking again, 726 left
proving every mutant is in the tree
building the tests, once
running the tests with nothing awake
  giving each mutant 93 seconds, from how long that took
asking each of 666 tests what it reaches
  nothing reaches 78 of them; the rest face 50.3 tests each, not the whole suite
running 726 mutants in 203 processes
  ...
420 killed  295 survived (78 of them unreached)  25 rejected  11 timed out  0 errored
score 59.37%  of covered code 66.51%
swift-mutants explain <id> says everything known about one of them.
```

## Being quick about it

A mutation run costs mutants times tests times launches, and each of the three is attacked
with something you can check rather than believe. Every number below is printed by the run
that made it, and every one is held by a test that fails when the saving stops happening.

| | Naive | Here | How |
| --- | --- | --- | --- |
| Compiles to find what the compiler refuses | one per module layer — **19** on this package | **3** | every module asked at once, against the interfaces a pristine build produced |
| Test executions | 726 x 666 ≈ **484,000** | **≈ 33,000** | a mutant faces the tests that reach it; 78 are answered with no process at all |
| Processes started | **726** | **203** | mutants that share no test run in one process, and it stops when every one of them is decided |
| A second run, unchanged | all of it | **none of it** | an answer is kept while the mutant, this build, and every file its tests were seen to run are unchanged |

That last row is the one worth watching: the same package measured twice, back to back,
gave the same score, the same survivors in the same order, and the second time it asked no
test what it reaches and started no process for any mutant. The two runs took 41m51s and
1m31s.

## What is there

| | |
| --- | --- |
| **Pure core** | byte spans, SHA-256, content-addressed mutant identities, catalogue, score, glob, interval forest |
| **Observability** | always-on trace with a bounded ring, one choke point that records every subprocess, a diagnostics bundle written when a run fails |
| **A scripted toolchain** | a `swift` and an `xcodebuild` that hang, print garbage or leave a red baseline on demand, so the unit tier can test what happens when a real one misbehaves |
| **Configuration** | a TOML reader that refuses an unknown key with the line it was written on |
| **Snapshot** | a disposable copy that refuses links and special files, owned by the run that made it and swept when its owner is gone |
| **Discovery** | comparisons, connectives and their operand prunes, boolean literals, arithmetic, compound assignment and bitwise — with precedence resolved, arid suppression, and comment pragmas |
| **Instrumentation** | every mutant in one tree behind a runtime guard, the line count unchanged, and an activation proof |
| **Validation** | every module asked at once, from SwiftPM's own plan, lowered rather than merely type-checked; halving is the fallback, not the mechanism |
| **Coverage** | each test asked once what it reaches, so a mutant faces the handful that can catch it — and a test whose probe did not finish is offered to everything rather than treated as reaching nothing |
| **Execution** | one build, the event stream watched live, mutants that share no test batched into one process that stops the moment all of them are decided |
| **Remembering** | an answer kept between runs while everything it rests on is unchanged, including the test files |
| **Reports** | `run --json`, a stored report, `report latest`, and `explain <id>` for one mutant's whole story |

The instrumented file is known to compile, to behave exactly as the original when nothing
is activated, to change exactly one thing when one mutant is woken, and to survive `-O`.

What is missing is the rest of the reporting and the second build system: the Stryker
projection, the offline HTML, SARIF, `--shard`, `report merge`,
trivial-compiler-equivalence, and the Xcode path. **Nothing is published, tagged, or
released, and the command tree will change.**

## Trying it

```sh
swift build -c release
.build/release/swift-mutants doctor        # can this machine run it
.build/release/swift-mutants list          # what would it measure, without measuring
.build/release/swift-mutants run           # measure it
.build/release/swift-mutants run -- --skip SlowTests   # your arguments, verbatim
.build/release/swift-mutants explain <id>  # one survivor's whole story
.build/release/swift-mutants report latest # the last run, as JSON
```

A mutant is answered from an earlier run only while everything that answer rests on is
unchanged: the mutant itself, this build of swift-mutants, and every file the tests that
reach it were seen to execute — the test files included. That assumes a test which runs a
file evaluates a mutant's guard somewhere in it, which holds everywhere except a region
where every statement was suppressed as arid. `--cache off` is the answer if you need the
guarantee rather than the speed.

Arguments after `--` go to your tests exactly as written and are never interpreted. They
are a scope as well as a setting: narrowing the suite narrows what the score is about.

### Tests that look at your source files

A test that asserts something about your *source* rather than about your *program* will
fail under instrumentation, because instrumentation changes those files by design. Lint
gates, import checks, golden files of source text, "no `print` in this module" rules — all
of them see a file with a guard in it and a runtime appended.

swift-mutants stops when that happens rather than reporting a score about a program nobody
has, and it names the tests:

```console
$ swift-mutants run
running the tests with nothing awake
Error: the instrumented tree does not behave like the one you wrote: with no mutant awake
the tests came back killed. Every later answer would be about a program nobody has, so the
run stops here.

These tests failed with nothing awake:
  RepositoryGateTests.AmbientGateTests/oneDoorway()
  RepositoryGateTests.PurityGateTests/importsAreConfined(module:)
  ... and 14 more
```

Exclude them and run again:

```sh
swift-mutants run -- --skip RepositoryGateTests
```

This repository's own gates are exactly this kind of test, which is how the message came
to exist.

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
| `mise run analyze` | Code nothing reads — a property, a function, an import, a whole module |

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
