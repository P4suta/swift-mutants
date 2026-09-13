#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 swift-mutants contributors
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Answers one question: can this machine develop swift-mutants?
#
# It runs before anything else in a fresh checkout, because the failures it reports are
# the ones that would otherwise surface as a confusing build error twenty minutes later.

set -euo pipefail

required_swift="${SWIFT_MUTANTS_REQUIRED_SWIFT:-6.3}"
status=0

report() { # ok|warn|fail, label, detail
    case "$1" in
    ok) printf '  \033[32m ok \033[0m %-22s %s\n' "$2" "$3" ;;
    warn) printf '  \033[33mwarn\033[0m %-22s %s\n' "$2" "$3" ;;
    fail)
        printf '  \033[31mfail\033[0m %-22s %s\n' "$2" "$3"
        status=1
        ;;
    esac
}

printf 'swift-mutants doctor\n\n'

if ! command -v swift >/dev/null 2>&1; then
    report fail "swift" "not on PATH"
else
    version="$(swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -1)"
    version="${version:-$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1)}"
    case "$version" in
    "$required_swift"*) report ok "swift" "$version" ;;
    "") report warn "swift" "version not recognised in: $(swift --version 2>&1 | head -1)" ;;
    *) report fail "swift" "$version, but this package is gated against $required_swift" ;;
    esac
fi

for tool in swiftlint periphery ast-grep typos rumdl taplo yamllint actionlint zizmor shellcheck gitleaks committed lefthook; do
    if command -v "$tool" >/dev/null 2>&1; then
        report ok "$tool" "$(command -v "$tool")"
    else
        report fail "$tool" "not on PATH; run 'mise install'"
    fi
done

if command -v xcrun >/dev/null 2>&1 && xcrun --find swift-format >/dev/null 2>&1; then
    report ok "swift-format" "$(xcrun --find swift-format)"
else
    report fail "swift-format" "not found in the active toolchain"
fi

if git rev-parse --git-dir >/dev/null 2>&1; then
    report ok "git" "repository present"
else
    report fail "git" "not a repository; --changed and the hooks need one"
fi

printf '\n'
if [ "$status" -eq 0 ]; then
    printf 'This machine can develop swift-mutants.\n'
else
    printf 'Fix the failures above, then run this again.\n'
fi
exit "$status"
