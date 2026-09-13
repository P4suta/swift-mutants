<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Security policy

## Reporting

Report a vulnerability through GitHub's private advisory form on this repository rather
than in a public issue. Include what you did, what happened, and what you expected.

## What swift-mutants does to a machine it runs on

These are the properties the design holds itself to. A deviation from any of them is a
security bug, not a feature request.

- **Your working tree is read-only.** Every build, edit and test happens inside a
  disposable snapshot. The snapshot excludes `.git` and the report directory, and rejects
  symbolic links, junctions and special files rather than following them.
- **Test commands are trusted project code.** They run inside the snapshot with a
  per-worker temporary directory, but a snapshot is not an operating-system sandbox. Do
  not point swift-mutants at a package you would not already run `swift test` on.
- **Process trees are cleaned up.** Timeouts and interrupts kill the whole tree through a
  POSIX process group, not just the immediate child.
- **No network, and no telemetry**, at any point — including the HTML report, which is a
  single self-contained file that fetches nothing.
- **Diagnostics record the names of environment variables, never their values.** A
  diagnostics bundle is something people attach to a bug report.

## Supply chain

The repository is REUSE-compliant, pins every development tool through `mise`, pins every
GitHub Action to a commit SHA, and runs `osv-scanner`, `gitleaks` and `zizmor` on every
pull request and weekly.
