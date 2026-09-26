<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Pull request

## Summary

<!-- What changed, and why? -->

## User and compatibility impact

<!-- Note CLI, configuration, report-schema, stable-ID or migration implications.
     A rule's name and version participate in mutant identity: changing what a
     rule emits changes every ID it mints, and invalidates cached answers rather
     than inheriting verdicts about different bytes. -->

## Validation

- [ ] `mise run check`
- [ ] `mise run test:integration` where a real toolchain decides the answer
- [ ] New behaviour has a test that was seen to fail before the change

## Honesty

<!-- The three ways this tool can lie, and the three things to check. -->

- [ ] No claim here asserts a condition nothing measured
- [ ] Evidence a later layer needs is not dropped at a boundary
- [ ] A number nobody measured is `null`, never a sentinel

## Release and privacy

- [ ] No generated mutation report, source-bearing diagnostic or secret is included
- [ ] Public contract changes carry documentation and schema fixtures
- [ ] `CHANGELOG.md` records anything a user would notice
