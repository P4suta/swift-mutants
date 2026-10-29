<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Guide to swift-mutants

## What it does

swift-mutants measures how well a Swift package's tests detect changes to its code.

It instruments compilable mutants once in a disposable snapshot, then activates each mutant in test processes through an environment variable.

The tool builds the package as written and keeps the working tree unchanged.

An [earlier self-measurement](https://github.com/P4suta/swift-mutants/blob/414c49079fc25b05361e1f20f76e631a5e5bcc3f/README.md) covers 751 mutants across 84 files.

The compiler refused 25 mutants, leaving 726 mutants for 666 tests across 203 processes.

That run reported 420 killed, 295 survived, 25 rejected, 11 timed out, and zero errored mutants.

The run took 41m51s, while the unchanged second run took 1m31s and reused every answer without probing tests or starting mutant processes.

The report lists three compiler invocations for rejection checks, compared with 19 for a plan with one invocation per module layer.

It reports about 33,000 test executions, compared with about 484,000 if all 666 tests ran for each mutant.

It reports 203 processes, compared with 726 if every mutant ran in a separate process.

The run classified 78 unreached mutants without starting processes to test those mutants.

The recorded output prints `score 59.37% of covered code 66.51%`.

## Status and requirements

The project measures Swift packages and reports a result.

The project has tested its Xcode building blocks with real Xcode, but `run` selects Swift Package Manager.

The project has published no release or version tag, and the command tree may change.

Build from source with Swift 6.3 or newer on macOS 15 or newer.

Use mise for the pinned development tools.

```sh
git clone https://github.com/P4suta/swift-mutants.git
cd swift-mutants
swift build -c release
```

From the repository root, `list` shows the planned measurement scope without measuring, and `run` measures the current package.

```sh
.build/release/swift-mutants doctor
.build/release/swift-mutants list
.build/release/swift-mutants run
```

The `run` command accepts test arguments after `--`, such as `.build/release/swift-mutants run -- --skip SlowTests`.

## How measurement works

The tool builds the package as written and instruments mutants into a disposable copy.

It asks the compiler to validate batches and checks each mutant's presence in the tree.

It builds tests once, asks each test what code it reaches, then batches mutants that share no tests into processes.

A run watches the event stream and stops a process once it decides every mutant in that process.

It reuses prior answers only while the mutant, build, and observed test files remain unchanged.

The suite's processor time determines each mutation's limit, and a wider wall-clock deadline stops deadlocks.

The run saves each answer when it decides the result.

It can emit trace records, diagnostic bundles, and canonical reports.

Validation confirms that each instrumented file compiles, behaves as the original when no mutant is active, changes one behavior when one mutant is active, and survives `-O`.

## Mutation families

The `balanced` profile is the default and includes comparisons, boolean connectives and operand pruning, boolean literals, integer arithmetic, whole-condition decisions, concatenation order, statement deletion, pattern guards, and swallowed failures.

The `strong` profile adds compound arithmetic assignment, bitwise operations, optional handling, range bounds, and collection ends.

The `all` profile adds integer literals shifted by one and removed unary minus.

An explicit `operators` list overrides the profile, and `why-skipped` reports rules outside the profile as skips.

The range-bound mutation shifts an exclusive upper bound while retaining the expression's type.

Optional coalescing mutations replace the expression with the fallback or force unwrap the optional value.

Statement deletion targets statements that bind no declaration, because deleting a declaration would change name visibility.

Pattern-guard mutations make eligible `where` conditions always true or false in switch cases, loops, and catches.

The tool replaces `try?` with `nil` to test whether swallowed failures matter, while preserving plain `try`.

Collection-end mutations use a fixed list of paired names such as `first`/`last`, `min`/`max`, and `prefix`/`suffix`.

The compiler can reject a mutation, such as a collection that exposes `first` but not `last`, and the tool reports that rejection.

The opt-in `extreme = true` setting replaces eligible function, computed-property, subscript, and accessor bodies with constants to test whether the suite observes their behavior.

This option defaults to off because it multiplies the catalogue by the number of declarations.

The tool skips bodies with unspellable return types, initializers, and `_read`/`_modify` accessors, and reports the reason for each skip.

## Configuration and reports

`swift-mutants init` writes a commented `.swift-mutants.toml` starter file, and `init --check` checks whether the tool can read the existing configuration.

Every command reads the same configuration, and unsupported settings cause an error that names their source line.

The `balanced` profile is the default, while `strong` and `all` add progressively larger operator sets.

`--changed[=REF]` narrows measurement to changes from a reference, including uncommitted work.

`--shard K/N` partitions the catalogue for separate machines, and `report merge` combines shard reports.

`--tce` asks the compiler to identify equivalent survivors, `--cache off` disables reuse, and `--strict` fails when an unrecorded survivor remains.

`--report json,html,sarif` selects report projections, while `report latest`, `explain <id>`, `browse`, and `apply <id>` inspect previous results.

The tool also provides trace summaries, cache status, and `why-skipped` explanations.

The tool measures expected mutants on every run and excludes them from the score while they survive.

A caught or missing expected mutant makes the expectation fail.

## Limits of a run

Tests that inspect source text can fail when instrumentation rewrites that source.

The tool stops if the instrumented tree fails its baseline and reports those tests.

The snapshot can omit tests that require fixtures outside the copied package, so mutants covered only by those tests can survive.

The test arguments after `--` narrow what the score measures, so document that scope when using the result in a gate.

## Development

The contribution guide requires test-driven changes and asks contributors to prove that new gates fail when inputs break their invariants.

`mise run check` is the quality gate for static analysis and the unit tier.

The unit tier excludes integration suites that depend on a toolchain, network access, or clock-sensitive behavior.

`mise run test:integration` drives a real Swift toolchain.

`mise run test:toolchain` exercises Xcode-specific integration, and `mise run gate:release` checks the optimized shipped configuration.

`./scripts/doctor.sh` checks local development prerequisites, and `mise run watch` runs the inner test loop.

The project enforces invariants with repository gate tests and `rules/ast-grep`, including mutation anchors, purity, test tiers, and manifest feature tracking.

## Related projects

The sibling mutation-testing projects are [njutest](https://github.com/P4suta/njutest), [go-mutants](https://github.com/P4suta/go-mutants), [gleam-mutants](https://github.com/P4suta/gleam-mutants), and [ocaml-mutants](https://github.com/P4suta/ocaml-mutants).

For the current Xcode design and its remaining work, see [ADR 0006](adr/0006-the-xcode-path-goes-through-the-xctestrun.md).

For development tool versions and tasks, see [mise](https://mise.jdx.dev).

## License

The project offers the [Massachusetts Institute of Technology license](../LICENSE-MIT) and [Apache License 2.0](../LICENSE-APACHE), at your option.
