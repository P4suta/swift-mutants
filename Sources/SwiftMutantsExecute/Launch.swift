// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsBuild
public import SwiftMutantsRunner

/// How one mutant is started.
///
/// A value rather than a step inside the runner, because something other than the runner
/// needs it: `explain` shows somebody the command that ran one mutant, and the only way
/// that line can be trusted is for it to come from here. A command assembled separately by
/// whatever prints it is a plausible-looking line that works until the day this adds a flag
/// - and then it silently runs a different program, the mutant behaves differently under
/// the debugger than it did in the report, and nobody can tell why.
public struct Launch: Sendable, Hashable {

    /// The bundle to start, and what to start it with.
    public let plan: TestPlan

    /// Which worker is asking, which the tests are told so they can keep apart.
    public let worker: Int

    /// How long it may take.
    ///
    /// The backstop rather than the limit, once there is an allowance. A deadline in wall
    /// time is a statement about the machine as much as about the program; it is kept for
    /// the one thing an allowance cannot see, which is a mutant that waits forever without
    /// working - a deadlock spends no processor at all.
    public let timeout: Duration?

    /// How much processor it may use, if this run could measure its own.
    public let cpuLimit: Duration?

    /// Records how a mutant is started.
    public init(plan: TestPlan, worker: Int, timeout: Duration?, cpuLimit: Duration? = nil) {
        self.plan = plan
        self.worker = worker
        self.timeout = timeout
        self.cpuLimit = cpuLimit
    }

    /// What to start, and what to tell it.
    ///
    /// Three arguments are added here rather than left to whoever built the plan, because
    /// all three are requirements of *watching* a run rather than of running one:
    ///
    /// - where to write its events, which only the caller knows, since the pipe is per
    ///   trial;
    /// - which spelling of the stream to use, pinned rather than left to a default;
    /// - `--no-parallel`, because swift-testing runs tests concurrently by default and
    ///   "which test killed this mutant" is then a race. Measured on the pinned toolchain:
    ///   four tests, three overlapping pairs by default and none with the flag.
    public func specification(
        writingEventsTo path: String, waking indices: [UInt32], onlyTests: [String]?
    ) -> ProcessSpec {
        var environment = plan.environment
        environment["SWIFT_MUTANTS"] = "1"
        environment["SWIFT_MUTANTS_TEST_TOKEN"] = "\(worker)"
        if !indices.isEmpty {
            environment["SWIFT_MUTANTS_ACTIVE"] =
                indices.map(String.init).joined(separator: ",")
        }

        // One `--filter` per test rather than one alternation, so no identifier has to
        // survive being spliced into a bigger pattern. Absent means the whole suite, which
        // is what a run without coverage has to do.
        let selection = (onlyTests ?? []).flatMap { ["--filter", Prober.exactly($0)] }

        return ProcessSpec(
            kind: indices.isEmpty ? .baseline : .mutant,
            executable: plan.executable,
            arguments: plan.arguments + [
                "--event-stream-output-path", path,
                "--event-stream-version", plan.eventStreamVersion,
                "--no-parallel",
            ] + selection,
            directory: plan.directory,
            environment: environment,
            timeout: timeout,
            cpuLimit: cpuLimit
        )
    }
}
