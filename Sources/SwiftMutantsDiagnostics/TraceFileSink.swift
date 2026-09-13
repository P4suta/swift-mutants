// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import Synchronization
public import SwiftMutantsTrace

/// Writes a run's account to a file, one JSON object per line.
///
/// The format is JSON Lines because a recording is read by `trace diff` and by whoever
/// opens it after a failure, and both want to be able to start in the middle. It also means
/// a recording of a run that died is still a readable recording of everything up to that
/// point - which is the recording somebody most often needs.
///
/// Writes are serialised. Workers record concurrently, and a line that arrived interleaved
/// with another would make the recording unreadable from that point on; the cost is a lock
/// held for the length of one line.
public final class TraceFileSink: TraceSink, Sendable {

    private let handle: Mutex<FileHandle?>

    /// The file being written to.
    public let path: URL

    /// Opens a recording at `path`, creating it and any directories above it.
    ///
    /// Throws rather than degrading to writing nowhere: `--trace` is a request for a file,
    /// and a run that quietly recorded to nothing would be discovered only by somebody
    /// looking for the recording after a failure.
    public init(at path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: path.path, contents: Data()),
            let opened = FileHandle(forWritingAtPath: path.path)
        else {
            throw Failure("cannot open \(path.path) for writing")
        }
        self.path = path
        handle = Mutex(opened)
    }

    /// Appends one event.
    ///
    /// A failure is thrown for the recorder to note. It is never fatal: a trace takes no
    /// part in a verdict, so a recording that cannot be written costs a warning rather than
    /// the run it was a recording of.
    public func record(_ event: TraceEvent) throws {
        var line = try event.jsonLine()
        line.append(contentsOf: Data("\n".utf8))
        try handle.withLock { handle in
            guard let handle else { throw Failure("\(path.path) is closed") }
            try handle.write(contentsOf: line)
        }
    }

    /// Finishes the recording.
    ///
    /// Writing after this fails, which is the shape a full disk takes and is what the
    /// recorder's note is for.
    public func close() throws {
        try handle.withLock { handle in
            try handle?.close()
            handle = nil
        }
    }

    /// A recording that could not be written.
    public struct Failure: Error, CustomStringConvertible {
        /// What went wrong, and where.
        public let description: String

        /// Creates a failure from an already-rendered description.
        public init(_ description: String) { self.description = description }
    }
}
