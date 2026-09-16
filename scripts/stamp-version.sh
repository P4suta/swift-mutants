#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 swift-mutants contributors
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Writes the version a build calls itself.
#
# The number lives in two places for one reason: `VERSION` is what a person and a release
# tool read, and `Version.swift` is what the binary reports into every document it writes.
# A build whose report says `0.0.0-dev` is a report nobody can trace back to a tag, so
# this is run before the release build and nowhere else.
#
# A development build keeps saying `0.0.0-dev`, which is the honest thing for it to say.
set -euo pipefail

tag="${1:?usage: stamp-version.sh vX.Y.Z}"
version="${tag#v}"

# Checked before anything is written, not after. A tag name is attacker-controlled - the
# text is chosen by whoever pushes it - and the first version of this wrote it into
# `VERSION` and only then noticed it was not a version, leaving the repository holding a
# release number with a semicolon in it.
#
# Nothing here ever put that text on a command line, so it was never a shell injection;
# it was the other half of the same mistake, which is trusting it as *data*.
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    printf 'stamp-version: %s is not a version\n' "$tag" >&2
    exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
printf '%s\n' "$version" > "$root/VERSION"

file="$root/Sources/SwiftMutantsCore/Version.swift"
tmp="$(mktemp)"
sed 's|public static let current = ".*"|public static let current = "'"$version"'"|' \
    "$file" > "$tmp"
mv "$tmp" "$file"

grep -q "\"$version\"" "$file" || {
    printf 'stamp-version: %s still does not name %s\n' "$file" "$version" >&2
    exit 1
}
printf 'stamped %s\n' "$version"
