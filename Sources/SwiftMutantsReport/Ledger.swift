// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

import SwiftMutantsCore

/// A run's answers, written down as they are decided.
///
/// A report is written once, when the run finishes. So a run killed a second before that is
/// indistinguishable from a run that never started: every answer existed, an hour of work
/// had been done, and the output is the same nothing. Reported from a package of 755 mutants
/// where the harness stopped the run for memory pressure at 755 of 755 - after the last
/// answer was in and before the summary was rendered.
///
/// The shape is the probe log's, and for the same reason. The file is opened once in append
/// mode and never closed; a line is written the moment an answer is known, with one `write`.
/// What was written before a process died is what it proved - no flush window, no handler
/// that has to run, nothing to lose between knowing and having written it down.
///
/// It is not a second report. A report is an account: scores, denominators, expectations,
/// everything a reader is owed. This is the answers, in the order they arrived, so that a
/// run somebody stopped is still a run somebody can read.
public final class Ledger: Sendable {

    /// One decided mutant, in the smallest form that is still worth having.
    ///
    /// Not a ``RunReport/Mutant``. That carries what a report needs - positions, the text
    /// either side of the edit, what reached it - and every field of it is a field that
    /// could fail to encode while a run is being killed. This is what somebody reading an
    /// interrupted run needs first: which mutant, where, and what happened.
    public struct Answer: Codable, Sendable, Hashable {

        /// The mutant's full identity, so a later report can be joined to this one.
        public let identity: String

        /// Which file it is in.
        public let path: String

        /// Which rule made it.
        public let rule: String

        /// What happened to it.
        public let outcome: String

        /// The tests that caught it, if any did.
        public let killedBy: [String]

        /// How long the trial took.
        public let durationMilliseconds: Int

        /// Records one answer.
        public init(
            identity: String,
            path: String,
            rule: String,
            outcome: String,
            killedBy: [String],
            durationMilliseconds: Int
        ) {
            self.identity = identity
            self.path = path
            self.rule = rule
            self.outcome = outcome
            self.killedBy = killedBy
            self.durationMilliseconds = durationMilliseconds
        }
    }

    private let descriptor: Int32

    /// Opens a ledger at `file`, or nothing when it cannot be opened.
    ///
    /// Nothing rather than throwing, because a run must not fail for being unable to keep a
    /// record of itself. The record is insurance against an interruption; refusing to start
    /// without it would turn a filesystem this cannot write into a run nobody gets.
    public init?(at file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = unsafe file.withUnsafeFileSystemRepresentation { path in
            unsafe path.map { unsafe open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644) } ?? -1
        }
        guard opened >= 0 else { return nil }
        descriptor = opened
    }

    deinit { close(descriptor) }

    /// Writes one answer down, now.
    ///
    /// One `write` of one line. Two workers answering at the same moment append two whole
    /// lines rather than interleaving halves of them: a write this size to a file opened
    /// `O_APPEND` is not split, which is the same guarantee the probe log rests on.
    ///
    /// An answer that cannot be encoded is skipped rather than raised. Nothing downstream
    /// of this depends on it, and a run that failed because its insurance failed would be a
    /// run lost to the thing that was there to prevent losing it.
    public func record(_ answer: Answer) {
        guard var line = try? JSONEncoder().encode(answer) else { return }
        line.append(0x0A)
        _ = [UInt8](line).withUnsafeBufferPointer { bytes in
            unsafe bytes.baseAddress.map { unsafe write(descriptor, $0, bytes.count) }
        }
    }

    /// The answers kept at `file`, in the order they arrived.
    ///
    /// A line the reader cannot decode is left out. That is the last line of a file whose
    /// writer was killed mid-write, and taking the readable part of it would be taking a
    /// smaller answer - which is exactly the shape of a wrong one.
    ///
    /// Nothing at all for a file that is not there, which is most runs: a run that finished
    /// has a report, and the report supersedes this.
    public static func read(_ file: URL) -> [Answer] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(Answer.self, from: Data($0.utf8))
        }
    }

    /// Where a package's ledger lives while a run is in flight.
    ///
    /// Beside the report and keyed the same way, so that whatever can find one can find the
    /// other - and outside the workspace, because the first rule of this tool is that the
    /// tree it was pointed at is only ever read.
    public static func location(for package: URL) -> URL {
        ReportStore.location(for: package)
            .deletingLastPathComponent()
            .appending(path: "in-flight-\(Self.name(of: package)).jsonl")
    }

    private static func name(of package: URL) -> String {
        DigestBuilder()
            .adding("swift-mutants-package")
            .adding(package.standardizedFileURL.path)
            .finalize()
            .hexadecimal
    }
}
