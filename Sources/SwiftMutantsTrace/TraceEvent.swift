// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Both appear in this file's public surface - Data from `jsonLine()`, Digest from an
// execution record - and InternalImportsByDefault would otherwise keep them internal.
public import Foundation
public import SwiftMutantsCore

/// One thing a run wrote down about itself.
///
/// Every run records, whether or not anybody asked for it: the failure nobody expected is
/// exactly the failure nobody passed `--trace` for. Without the flag the account is kept in
/// memory and written out only if the run fails; with it, the same events go to a file as
/// they happen.
///
/// **A trace is never evidence.** It takes no part in a verdict, in a mutant's identity, or
/// in a cache key, and a recording that cannot be written costs a warning rather than the
/// run. That is what lets it be complete without being load-bearing.
///
/// The wire format is one JSON object per line. It carries **durations, never timestamps**,
/// so that two recordings of the same tree differ only where the runs differed and
/// `trace diff` shows what changed rather than showing that time passed.
public struct TraceEvent: Sendable, Hashable {

    /// Where this event falls in the run's account. One-based and dense.
    public let sequence: Int

    /// What happened.
    public let kind: Kind

    /// Creates an event at a sequence position.
    public init(sequence: Int, kind: Kind) {
        self.sequence = sequence
        self.kind = kind
    }

    /// What a run can record.
    ///
    /// The set grows with the phases. A reader of an older recording refuses a kind it does
    /// not know rather than guessing at it, and the caller decides whether to skip the line
    /// or stop.
    public enum Kind: Sendable, Hashable {

        /// The run began, and what built it.
        case runStarted(runIdentifier: String, toolVersion: String)

        /// A phase began.
        case phaseBegan(phase: String)

        /// A phase finished, and how long it took.
        case phaseEnded(phase: String, durationMilliseconds: Int)

        /// A subprocess was started, or refused.
        ///
        /// Recorded at one choke point rather than at each call site. Processes are started
        /// from a dozen places, and a rule that every one of them must remember to record
        /// would have a dozen chances to be broken silently in exactly the run somebody is
        /// trying to diagnose.
        case exec(Execution)

        /// Something went wrong that did not stop the run.
        case warning(code: String, message: String)

        /// The run finished.
        ///
        /// A recording that does not end with this is a run still going, or one that died.
        /// The collector keeps such a recording rather than retiring it: the account of a
        /// crash is the one a reader most wants.
        case runEnded(outcome: String)
    }

    /// One subprocess, as the choke point saw it.
    public struct Execution: Sendable, Hashable {

        /// What kind of command it was, for a reader scanning the account.
        public let label: String

        /// The argument vector, verbatim. Never a shell string.
        public let arguments: [String]

        /// The working directory it was started in.
        public let directory: String

        /// The **names** of the environment variables it was given.
        ///
        /// Names only, never values. A diagnostics bundle is something people attach to a
        /// bug report, and a credential that reached a child process would otherwise reach
        /// the bug report too.
        public let environmentNames: [String]

        /// The deadline it was given, if it had one.
        public let timeoutMilliseconds: Int?

        /// Its exit status, or `-1` when it never became a process.
        public let exitCode: Int

        /// How long it ran.
        public let durationMilliseconds: Int

        /// A digest of what it printed, when any was retained.
        public let standardOutputDigest: Digest?

        /// How much it printed.
        public let standardOutputBytes: Int

        /// Why it could not be started, when it could not be.
        ///
        /// A command that never became a process is precisely what a reader needs to be
        /// told about, so it is recorded with `exitCode` `-1` rather than dropped.
        public let failure: String?

        /// Records one subprocess.
        public init(
            label: String,
            arguments: [String],
            directory: String,
            environmentNames: [String],
            timeoutMilliseconds: Int?,
            exitCode: Int,
            durationMilliseconds: Int,
            standardOutputDigest: Digest?,
            standardOutputBytes: Int,
            failure: String?
        ) {
            self.label = label
            self.arguments = arguments
            self.directory = directory
            self.environmentNames = environmentNames
            self.timeoutMilliseconds = timeoutMilliseconds
            self.exitCode = exitCode
            self.durationMilliseconds = durationMilliseconds
            self.standardOutputDigest = standardOutputDigest
            self.standardOutputBytes = standardOutputBytes
            self.failure = failure
        }
    }

    /// The event as one line of the recording, without its newline.
    ///
    /// Keys are sorted and slashes are left unescaped so that the bytes are the same on
    /// every machine and every run. Those bytes are pinned by a golden test rather than
    /// trusted: if a future Foundation changes how it writes them, the gate fails instead
    /// of two recordings quietly ceasing to be comparable.
    public func jsonLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
