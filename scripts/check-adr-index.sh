#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 swift-mutants contributors
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adr="${here}/docs/adr"
index="${adr}/README.md"

missing=0
for record in "${adr}"/*.md; do
	name="$(basename "${record}")"
	if [[ ${name} == README.md ]]; then
		continue
	fi
	if ! grep -qF "(${name})" "${index}"; then
		printf 'check-adr-index: %s is not listed in docs/adr/README.md\n' "${name}" >&2
		missing=1
	fi
done

for linked in $(grep -oE '\(([^()/]+\.md)\)' "${index}" | tr -d '()'); do
	if [[ ! -e ${adr}/${linked} ]]; then
		printf 'check-adr-index: docs/adr/README.md lists %s, which does not exist\n' \
			"${linked}" >&2
		missing=1
	fi
done

exit "${missing}"
