#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 swift-mutants contributors
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Every architecture decision record is listed in the index beside it.
#
# The index is written by hand, and a record that is not in it is a record nobody finds:
# 0009 was written, committed, and absent from the table for as long as it took somebody to
# read the directory rather than the index. A list kept in step with a directory by
# remembering to is wrong between the two commits nobody made.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adr="$here/docs/adr"
index="$adr/README.md"

missing=0
for record in "$adr"/[0-9]*.md; do
    name="$(basename "$record")"
    if ! grep -qF "($name)" "$index"; then
        printf 'check-adr-index: %s is not listed in docs/adr/README.md\n' "$name" >&2
        missing=1
    fi
done

for linked in $(grep -oE '\(([0-9]{4}-[^)]+\.md)\)' "$index" | tr -d '()'); do
    if [[ ! -e "$adr/$linked" ]]; then
        printf 'check-adr-index: docs/adr/README.md lists %s, which does not exist\n' \
            "$linked" >&2
        missing=1
    fi
done

exit "$missing"
