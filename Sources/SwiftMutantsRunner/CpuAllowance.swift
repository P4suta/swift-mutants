// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Running a command inside an allowance of processor time, and reading back what it used.
///
/// The unit is the whole point. A wall-clock deadline makes a verdict sensitive to
/// something that is not a property of the program: a mutant that met its deadline because
/// a build started in another window is recorded as a detection, and nobody ever finds out.
/// A process doing the same work consumes the same user and system seconds whether it is
/// alone on the machine or sharing it with seventeen others - the scheduler hands it fewer
/// per wall second, not fewer in total.
///
/// Both halves are the shell's, and both are POSIX rather than anything clever.
/// `ulimit -t` is `RLIMIT_CPU`, which the kernel enforces by sending `SIGXCPU` the instant a
/// process passes its allowance - nothing polls, nothing can drift, and a machine busy with
/// something else changes none of it. `times` prints what the shell's children used, which
/// is exactly this child and nothing around it.
///
/// It is not a perfect invariant and no claim is made that it is. A throttled core, or one
/// of Apple silicon's efficiency cores, does less work per processor second than a
/// performance core. Those vary far less than contention does, and they vary the same way
/// for the baseline a budget is derived from as for the trials it bounds.
enum CpuAllowance {

    /// The line the shell writes so that this can read what the child used.
    ///
    /// On standard error, because standard output is the child's answer and a line added to
    /// it would be a line whoever reads the answer has to know about. Taken off again
    /// before anybody sees the error stream either.
    static let marker = "swift-mutants-cpu"

    /// The same command, wrapped so that the kernel bounds it and the shell accounts for it.
    ///
    /// Not `exec`, deliberately: the shell has to outlive the child in order to report what
    /// it used. It costs one waiting process per trial, which is nothing beside a test
    /// bundle, and the process group is the shell's - so a deadline that kills the group
    /// still takes the child with it.
    ///
    /// The command arrives as an argument vector and leaves as one. Nothing is spliced into
    /// the script: the executable and its arguments are passed positionally and the script
    /// refers to them as `"$@"`, so a path with a space or a quote in it is a path rather
    /// than a fragment of shell.
    static func wrapping(
        _ executable: String, _ arguments: [String], within allowance: Duration
    ) -> (executable: String, arguments: [String]) {
        let seconds = max(1, Int(allowance.components.seconds))
        // `times` writes straight to the error stream rather than into a substitution.
        // A substitution and a pipeline are both subshells, and `times` in a subshell
        // reports *that* shell's children - which are none, so the measurement came back
        // zero for every command. It writes two lines: this shell's own, then its
        // children's, and the child is the second.
        let script = """
            ulimit -t \(seconds) 2>/dev/null
            "$@"
            status=$?
            echo "\(marker)" >&2
            times >&2
            exit $status
            """
        return ("/bin/sh", ["-c", script, "swift-mutants", executable] + arguments)
    }

    /// What the child used, out of one line of what the shell wrote.
    ///
    /// `times` prints `0m1.005s 0m0.015s` - user then system, minutes and seconds. Both are
    /// counted: a mutant that spends its allowance in the kernel has spent it.
    ///
    /// Nothing at all when the line is absent or unreadable, because nothing measured is
    /// not zero measured and a budget derived from zero is a budget nobody could meet.
    static func read(_ line: some StringProtocol) -> Int? {
        let fields = line.split(separator: " ").filter { $0.hasSuffix("s") }
        guard !fields.isEmpty else { return nil }
        var total = 0
        for field in fields {
            guard let milliseconds = Self.milliseconds(of: field) else { return nil }
            total += milliseconds
        }
        return total
    }

    /// One `0m1.005s` as milliseconds.
    private static func milliseconds(of field: some StringProtocol) -> Int? {
        let parts = field.dropLast().split(separator: "m")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Double(parts[1])
        else { return nil }
        return minutes * 60_000 + Int((seconds * 1000).rounded())
    }

    /// The child's output with this tool's accounting taken out, and what it said.
    ///
    /// A trial's standard error is read for what the tests said. A line this tool added in
    /// order to measure with would be a line somebody has to explain.
    static func taking(_ error: [UInt8]) -> (error: [UInt8], cpuMilliseconds: Int?) {
        let lines = String(decoding: error, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let marked = lines.firstIndex(of: Substring(Self.marker)) else {
            return (error, nil)
        }
        // The marker, this shell's own line, then the child's. Three lines, and all three
        // come off: what is left is what the child itself said.
        let ours = marked..<min(marked + 3, lines.count)
        let child = marked + 2 < lines.count ? Self.read(lines[marked + 2]) : nil
        var kept = lines
        kept.removeSubrange(ours)
        return (Array(kept.joined(separator: "\n").utf8), child)
    }

    /// The signal a process gets for passing its allowance, as an exit status.
    ///
    /// `SIGXCPU` is 24, and a shell reports a signalled child as `128 + n`. Named rather
    /// than written as a number, because 152 in a comparison is a number nobody can check.
    static let overrunStatus = 128 + 24
}
