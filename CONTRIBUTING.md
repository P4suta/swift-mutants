<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Contributing

## Getting set up

Development requires macOS 15 or later and Swift 6.3 or later.
Install the pinned tools and check the active toolchain before building.

```console
mise trust
mise install
mise run doctor
mise x -- lefthook install
```

## Development

Write a failing test before changing behavior.
Run the test and confirm the expected assertion fails.
Add the behavior and refactor with the test passing.
When changing a gate, introduce a representative violation and confirm the gate rejects it.

Keep domain decisions in pure modules and filesystem, process, and environment access in their adapters.
Failure paths need typed diagnostics and regression coverage in the same change.
Measurement tests must verify observed test results and activation rather than infer success from a build or exit code.

## Checks

`mise run check` runs static analysis and the unit tier across the repository.
The local hooks run fast checks before commits and the complete fast gate before pushes.
Run integration tests when a real Swift toolchain determines the result.

```console
mise run check
mise run test:unit
mise run test:integration
mise run analyze
mise run watch
```

`mise run analyze` runs Periphery over the package.
The release gate verifies optimized builds through `mise run gate:release`.

## Test tiers

Unit test target names end in `Tests` and may use process fixtures without launching Swift.
Integration target names end in `IntegrationTests` and exercise the real Swift toolchain.
`TestTierGateTests` checks target names and keeps toolchain access outside the unit tier.

## Source and commits

Write source, comments, documentation, and commit messages in English.
Use Conventional Commits with an imperative, unpunctuated subject under 72 characters.
The commit hook checks the message with `committed`.
