#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 swift-mutants contributors
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Runs Swift Testing with a concurrency policy that is stable across supported toolchains.
#
# Swift 6.3 links this package's test targets into one runner and lets the testing library schedule all of them in-process.
# Several tests supervise real subprocesses, so an unbounded run can occupy the cooperative executor until a child exits and starve the task that was meant to enforce its deadline.
# Swift 6.4 runs the test products separately and does not exhibit that starvation, so it keeps the fast parallel path.

set -euo pipefail

parallelism_requested=false
previous=""
for argument in "$@"; do
    if [[ "$previous" == "--scratch-path" ]]; then
        export SWIFT_MUTANTS_TEST_SCRATCH_PATH="$argument"
    fi
    case "$argument" in
    --scratch-path=*)
        export SWIFT_MUTANTS_TEST_SCRATCH_PATH="${argument#*=}"
        ;;
    --parallel | --no-parallel | --num-workers | --num-workers=*)
        parallelism_requested=true
        ;;
    esac
    previous="$argument"
done

if [[ "$parallelism_requested" == true ]]; then
    exec swift test "$@"
fi

version="$(swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -1)"
version="${version:-$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1)}"

if [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]] \
    && ((BASH_REMATCH[1] > 6 || (BASH_REMATCH[1] == 6 && BASH_REMATCH[2] >= 4))); then
    exec swift test --parallel "$@"
fi

exec swift test --no-parallel "$@"
