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
| **Observability** | always-on trace with a bounded ring, one choke point that records every subprocess, a diagnostics bundle written when a run fails, `--trace` to keep the recording and `trace summary` to say where the time went |
| **Durability** | answers are written down as they are decided, so a run killed at the last mutant is still a run somebody can read |
| **A scripted toolchain** | a `swift` and an `xcodebuild` that hang, print garbage or leave a red baseline on demand, so the unit tier can test what happens when a real one misbehaves |
| **Configuration** | a TOML reader that refuses an unknown key with the line it was written on, read by every command alike; `init` writes a starter file with every setting explained |
| **Snapshot** | a disposable copy that refuses links and special files, owned by the run that made it and swept when its owner is gone |
| **Discovery** | comparisons, connectives and their operand prunes, boolean literals, arithmetic, compound assignment and bitwise — with precedence resolved, arid suppression, and comment pragmas |
| **Instrumentation** | every mutant in one tree behind a runtime guard, the line count unchanged, and an activation proof |
| **Validation** | every module asked at once, from SwiftPM's own plan, lowered rather than merely type-checked; halving is the fallback, not the mechanism |
| **Coverage** | each test asked once what it reaches, so a mutant faces the handful that can catch it — and a test whose probe did not finish is offered to everything rather than treated as reaching nothing |
| **Execution** | one build, the event stream watched live, mutants that share no test batched into one process that stops the moment all of them are decided — the whole catalogue at once, so a batch is not confined to one file |
| **Limits** | a mutant is bounded by the processor time it uses, derived from your own suite and enforced by the kernel, so a busy machine cannot turn a survivor into a detection; the clock remains as the backstop for a deadlock, which spends no processor at all |
| **Remembering** | an answer kept between runs while everything it rests on is unchanged, including the test files |
| **Equivalence** | the compiler asked which survivors could never have been caught, by fingerprinting each one's optimised SIL against the original's |
| **Expectations** | survivors a project wrote down are measured every run and never answered from the cache; one that is caught, or whose identity has left the catalogue, fails the run |
| **Reports** | a canonical run report, the Stryker and SARIF projections, a single-file offline HTML page, GitHub annotations, `report latest`, `report merge`, and `explain <id>` for one mutant's whole story |
| **Promises kept** | every document is checked against the schema shipped beside it before it is written, by a validator that refuses a schema using a keyword it cannot check |
| **Watching it** | a screen that redraws on a terminal and lines into a pipe, the same closing block either way; `browse` walks the survivors afterwards |

The instrumented file is known to compile, to behave exactly as the original when nothing
is activated, to change exactly one thing when one mutant is woken, and to survive `-O`.

The Xcode path has its building blocks and not its wiring: reading a project's schemes,
building once with `build-for-testing`, waking a mutant through a copy of the `.xctestrun`,
and reading the result bundle are all built and tested against a real Xcode. `run` cannot
use them yet, because validation on that path has no equivalent of SwiftPM's build plan.
[ADR 0006](docs/adr/0006-the-xcode-path-goes-through-the-xctestrun.md) says what was
measured and what remains. **Nothing is published, tagged, or released, and the command
tree will change.**

## Trying it

```sh
swift build -c release
.build/release/swift-mutants doctor        # can this machine run it
.build/release/swift-mutants list          # what would it measure, without measuring
.build/release/swift-mutants why-skipped   # and what it passed over, with the reason
.build/release/swift-mutants run           # measure it
.build/release/swift-mutants run -- --skip SlowTests   # your arguments, verbatim
.build/release/swift-mutants explain <id>  # one survivor's whole story, and how to run it
.build/release/swift-mutants browse        # walk the survivors, one at a time
.build/release/swift-mutants apply <id>    # the same mutant as a patch, to step through
.build/release/swift-mutants report latest # the last run, as JSON
.build/release/swift-mutants init          # a settings file, with every setting explained
.build/release/swift-mutants cache status  # what answers are kept, and how to clear them
.build/release/swift-mutants trace summary # where a recorded run's time went
```

### Flags worth knowing

| | |
| --- | --- |
| `--report json,html,sarif` | write the documents a dashboard, a browser or code scanning reads |
| `--changed[=REF]` | measure only what differs from a reference, uncommitted work included |
| `--shard K/N` | take one machine's share of the catalogue; `report merge` puts the shares back together |
| `--tce` | ask the compiler which survivors could never have been caught, and say so rather than listing them |
| `--cache off` | measure everything, however little changed |
| `--strict` | exit 1 when anything survived that was not written down |
| `-v`, `-vv` | say how long each phase took; say what the run started, as it happens |
| `--quiet` | say nothing but errors — the exit code is the answer |
| `--no-tui` | print lines rather than drawing, even on a terminal |
| `--keep-temp` | keep the copy the run happened in, so `explain`'s command is one you can paste |
| `--trace` | keep a recording of everything the run starts; `trace summary` says where the time went |
| `-j`, `--jobs` | how many mutants at once. Defaults to this machine's cores, or to what its memory holds a test bundle for, whichever is fewer. A machine busy with other work wants this set: nothing derivable can tell a busy machine from an idle one of the same size |
| `--timeout` | one deadline for every mutant, instead of the allowance derived from your suite |

### What bounds a mutant

A mutation is the edit most likely to make a program stop terminating — a loop bound moved,
a comparison flipped, an index arithmetic changed. Something has to stop one, and what that
something measures decides whether a verdict is about your program or about your machine.

It is **processor time**, not the clock. A process doing the same work consumes the same
user and system seconds whether it is alone on the machine or sharing it with seventeen
others; the scheduler hands it fewer per wall second, not fewer in total. The allowance
comes from your own suite, measured in the same unit, and the kernel enforces it through
`RLIMIT_CPU` — so nothing polls, nothing drifts, and two runs at different `--jobs` agree
about what did not terminate.

A deadline is still there, widened well past the allowance, for the one thing an allowance
cannot see: waiting is not working, so a mutant that deadlocks spends no processor at all.

`--timeout` overrides both with one number for every mutant, which is an answer rather than
an input — so nothing is derived and nothing is second-guessed.

### Settings

`swift-mutants init` writes a `.swift-mutants.toml` with every setting commented out and
explained, and `init --check` says whether the one you have can be read — exit 2 if not,
which is the shape for a gate. Every command reads it, `list` and `why-skipped` included,
so what `list` describes is what `run` would do.

### Which operators run

`profile` picks a tier, and each tier contains the one below it:

| Tier | Adds |
| --- | --- |
| `balanced` (the default) | comparison, boolean connectives and their pruning, boolean literals, integer arithmetic, whole-condition decisions, concatenation order, statement deletion |
| `strong` | compound arithmetic assignment, bitwise, optional handling, range bounds, collection ends |
| `all` | nothing yet — the rules its tier is for are not built |

`operators = ["lt-to-le"]` names them outright and wins over the tier, because a name is
more specific than a tier.

A rule a tier leaves out is a **skip**, not a silence: `why-skipped` reports it as
`outside-profile`, with the count of mutants it cost, and a rule you did not name as
`not-selected`. A catalogue that got smaller than you expected always has something to ask.

`swift-mutants init` writes the tier table into your settings file from the same table a run
reads, so the explanation you are handed cannot drift from the run you get.

### Settings that do something

Every setting in the file is read by a run, and one this build cannot honour is **refused
with the line it is on** rather than stored and ignored. `strict` and `minimum_score` gate
the exit code; `formats`, `directory`, `high` and `low` decide what is written and how the
headline is marked; `baseline_runs` decides how many times the baseline is measured before
it is trusted.

A suite that does not give the same answer twice about the same program makes every verdict
below it meaningless — a mutant is reported as caught by a failure that had nothing to do
with it — so the baseline is measured `baseline_runs` times and a disagreement is named for
what it is, rather than blamed on the instrumentation.

### The two families Swift has that other languages do not

A range and a coalescing operator are where Swift puts the two mistakes every language
makes: the off-by-one, and the decision about what to do when there is nothing.

`a..<b` becomes `a..<(b + 1)` — the fencepost, written down. Not `..<` swapped for `...`,
which was the obvious rule and does not work: the two build *different types*, and the
guard around a mutant needs both its branches to be the same one. Shifting the bound keeps
the type by construction.

`a ?? b` becomes `b`, which asks whether anything ever tests the case where `a` is there,
and `(a)!`, which asks whether anything tests the case where it is not — and traps where
nothing does, which is a detection rather than a wrong answer. The two sides are written
differently for the same reason as above: `b` is already the type of the whole expression
and `a` is the optional.

### A statement that does not run

The plainest question in mutation testing — if this line never ran, would anything notice?
— and by volume the largest family there is. Google's measurement over six years of a
two-billion-line monorepo put statement deletion at 68% of every mutant they generated and
around 80% productivity, the highest of any operator they kept, which is why it is in
`balanced` rather than above it. It is 1154 mutants in this repository.

Only statements that bind nothing: a call whose value is discarded, and an assignment to
something that already exists. A `let` skipped this way would take its name out of scope
for everything below it, which is not a mutant but a different program — and a block of one
statement is never touched, because in a function body that statement is the implicit
return and in a `guard` it is the only thing stopping a fall-through.

### The ends of a collection

Every other rule changes an operator. This one changes a **name**: `first` for `last`,
`min` for `max`, `prefix` for `suffix`, `dropFirst` for `dropLast`, `hasPrefix` for
`hasSuffix`, `firstIndex` for `lastIndex`, `removeFirst` for `removeLast`. Swift spells the
two ends of a sequence in matched pairs that return the same type as each other, which is
what lets one guard hold both — and they are the same length, the same shape, and next to
each other in every autocomplete list there has ever been.

A fixed list, and nothing is guessed: a rule matching on a prefix would call
`firstResponder` an end of a collection. Where a receiver has only one of the two — a `Set`
has `first` and no `last` — the compiler refuses the mutant and it is reported as a
rejection, in the compiler's own words.

### Replacing a body outright

`extreme = true` adds a rule that asks a different question from the rest of the catalogue:
not whether one operator is right, but whether the declaration is **tested at all**. It
replaces a body with a constant, and a survivor is a declaration your tests run and assert
nothing whatever about — a median of one method in ten, across every project the literature
has surveyed. It produces almost no equivalent mutants, because a body that can be replaced
by a constant with nothing noticing is a finding whichever constant was chosen.

Two shapes, because Swift has two kinds of place to put a guard. A body that is one
expression takes a ternary, which disturbs nothing around it. A body of several statements
is not an expression, so its guard is a statement in front of it — placed on the brace's own
line, so every line number below is what it was. That second shape is also what lets a
function **that returns nothing** be measured at all: there is no value to put in a
ternary's branches, and "does anything notice when this stops doing its work" is the
sharpest question that can be asked about a procedure.

Functions, computed properties in both the spellings Swift has for them, subscripts, and
the accessors of each — a setter or a `didSet` that does nothing is exactly the shape this
looks for, since a body whose whole purpose is a side effect has no other question worth
asking about it.

Two things are passed over, and both say so. A return type with no value anybody can write
down — `some P`, `any P`, a generic parameter, a type of your own — is
`unspellable-return-type`. An initialiser, or a `_read`/`_modify` accessor, is
`unstoppable-body`: returning early from the first leaves the instance half-built and from
the second traps before the yield, so there is no mutant there to have.

Off until you ask, because it multiplies the catalogue by the number of declarations rather
than by the number of operators, and that is a decision about how long a run takes.

### Survivors you have accounted for

Some survivors are not holes. A mutant in code unreachable by construction survives every
suite anybody writes, and a list that never shrinks below those is a list nobody reads.

```toml
[[mutation.expect]]
id = "4fcc205c…"            # the full sixty-four characters a report prints
reason = "unreachable by construction: the caller checks this first"
```

This is not a skip list, and the difference is the whole design. An expected mutant is
measured on every run and never answered from the cache. If it survives, the expectation is
met and it leaves the score's denominator. If something catches it, somebody wrote the
assertion and the note has become untrue. If its identity is no longer in the catalogue,
the code moved and nobody updated the note. The last two exit 2.

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

### Tests that cannot run in the copy

The other half of the same fact. A test whose fixtures live *outside* the package — a
document in the repository above it, a vector file, a seed corpus — cannot run in a copy of
the package alone, and a suite written to notice that declares itself disabled rather than
failing:

```swift
@Suite("Base32 matches the spec", .enabled(if: Repository.isPresent))
```

swift-testing reports that on the event stream, and swift-mutants says so before it
measures anything:

```console
running the tests with nothing awake
2 of your tests stepped aside in the copy this run happens in:
  VectorTests.Base32Spec/alphabet()
  VectorTests.CascadeSpec/saltOrder()

A test whose fixtures live outside the package — a document in the repository above it, a
vector file, a seed corpus — cannot run in a copy of the package alone. Anything only those
tests cover cannot be caught here, and will report as surviving however good they are.
Pinning the same constant inside the package is the answer; writing another test is not.
```

That last sentence is the point of saying it. Those mutants are survivors nobody can fix by
writing a test, because the test already exists and cannot run here — so a `--strict` gate
over the list can never go green until the constant is pinned a second time, inside the
package. Nobody arrives at that while the tool is silent, and a skipped test used to be
indistinguishable from one that ran and passed.

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
