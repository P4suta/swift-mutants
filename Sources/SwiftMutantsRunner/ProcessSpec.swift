// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// One command a run wants to start.
///
/// Assembled as a value rather than passed as loose arguments, so that the thing which
/// starts processes has exactly one shape of input and exactly one place to record it.
public struct ProcessSpec: Sendable, Hashable {

    /// What kind of command this is, for a reader scanning the account.
    ///
    /// An enum rather than a string, which is the whole point: recording at the choke point
    /// means a call site cannot forget to record, and a closed label means it cannot get
    /// the label wrong either. A new kind of command is a new case here, which is a change
    /// somebody reviews.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// `swift --version`, or whatever else establishes that a toolchain is there.
        case versionProbe = "version-probe"
        /// Asking the package manager what a package contains.
        case describe
        /// Building, including building tests.
        case build
        /// Type-checking an instrumented tree, for compile validation.
        case typecheck
        /// Emitting SIL, for trivial-compiler-equivalence.
        case emitSIL = "emit-sil"
        /// The baseline suite, with nothing activated.
        case baseline
        /// Profiling a test to find out what it reaches.
        case coverage
        /// One mutant, activated.
        case mutant
        /// One probe run against the probe tree.
        case probe
        /// Something a test in this repository scripted.
        case testFixture = "test-fixture"
    }

    /// What kind of command this is.
    public let kind: Kind

    /// The program to start. An absolute path, never a shell string.
    public let executable: String

    /// Its arguments, verbatim. Never handed to a shell.
    public let arguments: [String]

    /// The directory to start it in.
    public let directory: String

    /// The whole environment it gets.
    ///
    /// Whole rather than added to the ambient one: a run that inherited whatever happened to
    /// be set could not be reproduced from its own recording, and the recording would have
    /// to name variables the run never chose.
    public let environment: [String: String]

    /// How long it may take, if it has a deadline.
    public let timeout: Duration?

    /// How much processor it may use, if it has an allowance.
    ///
    /// The unit a limit on a mutant belongs in. A wall-clock deadline makes a verdict
    /// sensitive to something that is not a property of the program - a mutant that met its
    /// deadline because a build started in another window is recorded as a detection -
    /// whereas a process doing the same work consumes the same user and system seconds
    /// whether it is alone on the machine or sharing it with seventeen others. The
    /// scheduler gives it fewer per wall second, not fewer in total.
    ///
    /// Enforced by the kernel through `RLIMIT_CPU`, which sends `SIGXCPU` the moment a
    /// process passes its allowance: nothing polls and nothing can be got wrong. A child
    /// that only waits is untouched, which is exactly right - waiting is not working - and
    /// is why ``timeout`` remains as the backstop for the one thing this cannot see.
    ///
    /// Not a perfect invariant, and no claim is made that it is: a throttled core, or one
    /// of Apple silicon's efficiency cores, does less work per processor second than a
    /// performance core. Those vary far less than contention does, and they vary the same
    /// way for the baseline a budget is derived from as for the trials it bounds.
    ///
    /// Whole seconds, because that is the unit the limit is expressed in. Absent for
    /// everything that is not a mutant under measurement.
    public let cpuLimit: Duration?

    /// Describes one command.
    public init(
        kind: Kind,
        executable: String,
        arguments: [String],
        directory: String,
        environment: [String: String],
        timeout: Duration?,
        cpuLimit: Duration? = nil
    ) {
        self.kind = kind
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.timeout = timeout
        self.cpuLimit = cpuLimit
    }

    /// The variables this tool sets, as opposed to the ones it passes on.
    ///
    /// A line somebody reads carries these and not the rest. The whole environment would be
    /// unreadable; worse, it would put whatever a developer has exported - tokens, keys -
    /// into a terminal they are about to paste into a bug report.
    public static let ours = "SWIFT_MUTANTS"

    /// This command as a line a shell would run.
    ///
    /// For showing somebody what ran, never for running anything: every process this tool
    /// starts is started from an argument vector, and a shell is not involved at any point.
    /// That is what makes the quoting here a presentation detail rather than a place an
    /// injection could hide.
    /// `showing` names variables to carry besides this tool's own. A run works them out
    /// rather than inheriting them - on a Mac a test bundle is a dylib that needs
    /// `Testing.framework` on its search path - so a command without them fails to load and
    /// looks like a bug in the package. Everything else the run inherited stays out: a line
    /// carrying somebody's whole environment would be unreadable, and one carrying their
    /// tokens would end up in a bug report.
    public static func rendered(_ spec: Self, showing names: Set<String> = []) -> String {
        let variables = spec.environment
            .filter { $0.key.hasPrefix(Self.ours) || names.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(quoted($0.value))" }
        return (variables + [quoted(spec.executable)] + spec.arguments.map(quoted))
            .joined(separator: " ")
    }

    /// One word, quoted only when a shell would otherwise read it as more than one.
    ///
    /// Single quotes, because nothing inside them means anything to a shell, and a literal
    /// single quote is spelled by leaving the quoting and coming back - which is the one
    /// arrangement that is right for every byte.
    private static func quoted(_ word: String) -> String {
        let plain = word.allSatisfy {
            $0.isLetter || $0.isNumber || "-_./=:,@+".contains($0)
        }
        guard !plain || word.isEmpty else { return word }
        return "'"
            + word.split(separator: "'", omittingEmptySubsequences: false)
            .joined(separator: #"'\''"#) + "'"
    }
}

/// What became of a command.
/// What became of a command.
///
/// It does not say which signal ended a process that one ended. Nothing reads that, and a
/// field carried for an option nobody has taken is a second place for it to be wrong; the
/// exit status says a process ended abnormally and `Termination` says what that means about
/// a mutant. If the number itself becomes worth having - a trap tells you something a
/// non-zero exit does not - it comes back with a reader and a test.
public struct ProcessOutcome: Sendable {

    /// Its exit status, or `-1` when it never became a process.
    public let exitCode: Int

    /// How much processor it used, when it was asked to account for it.
    ///
    /// `nil` for every command given no allowance, which is every build and every probe.
    /// Nothing measured is not zero measured, and a budget derived from zero would be a
    /// budget nobody could meet.
    public let cpuMilliseconds: Int?

    /// Whether it was stopped for overrunning its deadline.
    public let timedOut: Bool

    /// Whether the kernel stopped it for passing its allowance of processor time.
    ///
    /// Different news from a deadline, and better news: a deadline says nothing was learned
    /// in the time allowed, which on a busy machine may be a fact about the machine. This
    /// says the process did more *work* than the allowance, which is a fact about the
    /// program and is the same on any machine.
    public var overranCpu: Bool { exitCode == CpuAllowance.overrunStatus }

    /// Whether it was stopped because whoever was watching it had its answer.
    ///
    /// Distinct from ``timedOut`` because they mean opposite things: a deadline means
    /// nothing was learned in the time allowed, and this means everything was. Both end
    /// with a signal, so without the distinction a kill and a hang would look alike.
    public let stoppedEarly: Bool

    /// How long it ran.
    public let durationMilliseconds: Int

    /// The first ``Runner/outputLimit`` bytes it printed to standard output.
    public let standardOutput: [UInt8]

    /// The first ``Runner/outputLimit`` bytes it printed to standard error.
    public let standardError: [UInt8]

    /// Why it could not be started, when it could not be.
    public let startFailure: String?

    /// Where its record sits in the run's account.
    ///
    /// Handed back so that an error travelling up three layers can still say which
    /// recorded command it was about.
    public let traceSequence: Int

    /// What it printed to standard output, as text.
    ///
    /// Read as UTF-8 with anything invalid replaced rather than refused: a command's output
    /// is something to show a person, and a tool that could not report what a failing
    /// command said because the bytes were not quite text would be a tool reporting nothing
    /// exactly when there is something to report.
    public var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }

    /// The same for standard error, which is where most tools put the reason.
    public var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}
