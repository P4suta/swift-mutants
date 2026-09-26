#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 swift-mutants contributors
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Answers one question: does the configuration this repository ships actually work?
#
# Every other tier compiles without the optimiser. The unit tier asserts about libraries
# in a debug build, the integration tier drives a toolchain from a debug build, and both
# were green - 1137 of them - on a day the release binary died in `swift_retain` part way
# through a run. The thing tested was not the thing shipped, so nothing that was tested
# could have said so. An optimiser-dependent fault has no debug tier that can see it.
#
# Three properties, and the gate is worth little without any of them.
#
# Optimised. The suite is compiled `-c release` and run, so a library whose behaviour
# changes under the optimiser fails here rather than in somebody's terminal.
#
# Built from nothing. SwiftPM's incremental build has been observed on this package to
# leave a module compiled against a layout a dependency no longer has - three times in the
# debug tree, each one fixed by deleting it. An incremental gate would sometimes measure a
# tree nobody can reproduce, which is the failure this whole project exists to refuse: a
# result indistinguishable from a real one.
#
# Everything that was *compiled*, and nothing that was *downloaded*. The dependency
# checkouts are sources pinned by `Package.resolved` and are the same bytes every run, so
# deleting them measures nothing new - it only makes the gate re-clone, which needs a
# `git checkout --force` that a machine may quite reasonably refuse. What goes is every
# product and intermediate, which is what "recompiled from nothing" means.
#
# In its own scratch directory. `.build` belongs to the inner loop, and a gate that wiped
# it would cost a full debug rebuild every time somebody ran the gate once. Separate trees
# also mean the release gate cannot inherit anything from a debug build, which is the only
# way "from nothing" is true rather than merely intended.

set -euo pipefail

scratch="${SWIFT_MUTANTS_RELEASE_SCRATCH:-.build-release}"
strict_flags="${SWIFT_MUTANTS_STRICT_BUILD_FLAGS:--Xswiftc -warnings-as-errors}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p "$scratch"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

say "wiping what $scratch compiled, so this measures a tree built from nothing"
for built in "${scratch:?}"/*; do
    case "$(basename "$built")" in
    checkouts | repositories | artifacts | workspace-state.json | CACHEDIR.TAG) continue ;;
    *) rm -rf "$built" ;;
    esac
done

# The dependencies come from wherever they already are, rather than being cloned again.
#
# They are pinned by `Package.resolved`, so a second copy is the same bytes by definition -
# fetching it costs the network, and checking it out costs a `git checkout --force` that a
# machine may quite reasonably refuse. Copying what the inner loop already resolved is the
# same sources, arrived at without asking anybody's permission to reset a repository.
#
# Absent is fine: SwiftPM resolves them itself, which is what a fresh checkout does.
for shared in checkouts repositories workspace-state.json; do
    if [[ ! -e "$scratch/$shared" && -e ".build/$shared" ]]; then
        cp -R ".build/$shared" "$scratch/$shared"
    fi
done

# `-enable-testing` because the suite uses `@testable import` in 134 places, and without
# it a release test build fails to load the modules rather than telling the truth about
# them. It costs some cross-module optimisation, which is why the end-to-end run below
# exists as well: that one builds the product exactly as a release builds it.
say "running the unit tier with the optimiser on"
# shellcheck disable=SC2086  # the flags are a deliberate word list, not one argument
./scripts/swift-test.sh -c release $strict_flags \
    -Xswiftc -enable-testing \
    --scratch-path "$scratch" \
    --skip IntegrationTests --skip ToolchainTests

# Everything rather than one product: building the whole package also produces the
# scripted toolchain the dogfood run needs, and a gate that built only what it was about
# to run would not notice a target that stopped compiling.
say "building the executable the way a release builds it"
# shellcheck disable=SC2086
swift build -c release $strict_flags --scratch-path "$scratch"

binary="$scratch/release/swift-mutants"
if [[ ! -x "$binary" ]]; then
    echo "the build reported success and left no executable at $binary" >&2
    exit 1
fi

# A subject with a known answer, because a gate that only checks the exit code passes on
# a tool that found nothing and said so politely. One function a test asserts about and
# one it does not: the first has to come back killed and the second has to come back
# survived, and a run reporting neither has not exercised the pipeline it claims to.
subject="$(mktemp -d)"
trap 'rm -rf "$subject"' EXIT

mkdir -p "$subject/Sources/Subject" "$subject/Tests/SubjectTests"

cat >"$subject/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Subject",
    targets: [
        .target(name: "Subject"),
        .testTarget(name: "SubjectTests", dependencies: ["Subject"]),
    ]
)
PACKAGE

cat >"$subject/Sources/Subject/Subject.swift" <<'SOURCE'
public enum Subject {

    /// Asserted about, so a mutant of it has to die.
    public static func add(_ a: Int, _ b: Int) -> Int { a + b }

    /// Asserted about by nothing, so a mutant of it has to live.
    public static func scale(_ a: Int, _ b: Int) -> Int { a * b }
}
SOURCE

cat >"$subject/Tests/SubjectTests/SubjectTests.swift" <<'TESTS'
import Testing

import Subject

@Test func addsTwoNumbers() {
    #expect(Subject.add(2, 3) == 5)
}
TESTS

say "running the shipped binary against a package whose answer is known"
report="$subject/report.json"
complaint="$subject/stderr.txt"
# The status of the command, not of the `if`. Reading `$?` inside the body gives the
# latter, which is always 0 - so a gate written that way reports every failure as "exit
# status: 0" and buries the signal it was watching for.
status=0
"$binary" run --package-path "$subject" --no-tui --cache off --json \
    >"$report" 2>"$complaint" || status=$?
if [[ "$status" -ne 0 ]]; then
    echo "the shipped binary did not complete a run of a two-function package" >&2
    echo "  exit status: $status" >&2
    echo "  (128+n is a signal: 139 is a segmentation fault, 134 an abort)" >&2
    # Its own words. `--json` sends the report to stdout, so everything the tool says
    # about a failure is on stderr - and a gate that showed only stdout would show an
    # empty file and call it the evidence.
    echo "  it said:" >&2
    sed -n '1,40p' "$complaint" >&2
    exit 1
fi

say "checking the run reported the answer this package has"
killed="$(jq -er '.summary.killed' "$report")"
survived="$(jq -er '.summary.survived' "$report")"
printf '  killed %s, survived %s\n' "$killed" "$survived"

if [[ "$killed" -lt 1 ]]; then
    echo "a test asserts about \`add\`, so a mutant of it had to die, and none did" >&2
    exit 1
fi
if [[ "$survived" -lt 1 ]]; then
    echo "nothing asserts about \`scale\`, so a mutant of it had to live, and none did" >&2
    exit 1
fi

say "the shipped configuration works"
