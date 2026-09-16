// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import SwiftMutantsCore
public import SwiftMutantsRunner

/// Which files have changed, so a run can measure those and say so.
///
/// The honest answer to "fast enough to leave switched on". A whole-package run is
/// `Θ(mutants)` however clever the scheduling, and on a package of any size that is not
/// something anybody puts in a pre-push hook. A run scoped to what somebody just wrote is
/// `Θ(mutants in the files they touched)`, which is a handful.
///
/// Uncommitted work counts. The change a person most wants measured is the one they have
/// not committed yet, and a scope that only saw commits would be useless in the loop it
/// exists for.
///
/// This is preferred over caching verdicts across runs, and the reason is soundness rather
/// than effort: a mutant's verdict depends on which tests reach it, and which tests reach
/// it can change because some *other* file changed. A cache key honest about that has to
/// include the whole tree, at which point it only helps when nothing changed at all. A
/// scope makes no claim about the mutants it did not run, and says so.
public struct ChangedFiles: Sendable {

    private let root: URL
    private let runner: Runner
    private let git: String

    /// Prepares to ask git about the package at `root`.
    public init(root: URL, runner: Runner, git: String = "/usr/bin/git") {
        self.root = root
        self.runner = runner
        self.git = git
    }

    /// The paths that differ from `reference`, including work not yet committed.
    ///
    /// Two questions, because git answers them separately: what differs from the reference
    /// in tracked files, and what is not tracked at all. A new file is the most likely
    /// thing to want measured and the most likely to be missed.
    public func since(
        _ reference: String, environment: [String: String] = [:]
    ) async throws(RunError) -> Set<WorkspaceRelativePath> {
        let tracked = try await ask(
            ["diff", "--name-only", reference], environment: environment)
        let untracked = try await ask(
            ["ls-files", "--others", "--exclude-standard"], environment: environment)
        return Set((tracked + untracked).compactMap { WorkspaceRelativePath($0) })
    }

    private func ask(
        _ arguments: [String], environment: [String: String]
    ) async throws(RunError) -> [String] {
        let outcome = await runner.run(
            ProcessSpec(
                kind: .describe,
                executable: git,
                arguments: arguments,
                directory: root.path,
                environment: environment,
                timeout: .seconds(60)
            )
        )
        if let failure = outcome.startFailure {
            throw RunError("cannot run \(git): \(failure)")
        }
        guard outcome.exitCode == 0 else {
            if let stopped = outcome.stoppedFromHere(after: .seconds(60)) {
                throw RunError(
                    "`git \(arguments.joined(separator: " "))` \(stopped) in \(root.path).")
            }
            let complaint = String(decoding: outcome.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RunError(
                """
                `git \(arguments.joined(separator: " "))` exited \(outcome.exitCode) in \
                \(root.path).
                \(complaint.isEmpty ? "It said nothing." : complaint)
                """
            )
        }
        return String(decoding: outcome.standardOutput, as: UTF8.self)
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
