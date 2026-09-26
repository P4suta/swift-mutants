#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 swift-mutants contributors
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# A filtered test run that fails when the filter matched nothing.
#
# `swift test --filter` matches type names. Given a name nothing has - a target renamed, a
# suite's display name typed in place of its type - it prints `No matching test cases were
# run` as a *warning* and exits 0. A task that only reads the exit status then reports a
# tier as passing when the tier did not run, and the tier most likely to be filtered is the
# one hardest to run by hand, so nobody notices.
#
# Found by making the mistake: a filter written from an `@Suite` display name ran no tests,
# exited 0, and was read here as green.

set -euo pipefail

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

set +e
./scripts/swift-test.sh "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e

if grep -q 'No matching test cases were run' "$log"; then
    printf 'filtered-tests: the filter matched no tests, so this tier did not run.\n' >&2
    printf 'filtered-tests: a filter matches type names, not @Suite display names.\n' >&2
    printf 'filtered-tests: arguments were: %s\n' "$*" >&2
    exit 1
fi

exit "$status"
