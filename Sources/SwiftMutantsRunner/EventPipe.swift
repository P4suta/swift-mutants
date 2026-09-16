// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

import Dispatch
import Synchronization

/// A named pipe a child process writes lines into while it runs.
///
/// swift-testing writes its event stream as one JSON object per line, and pointed at a
/// named pipe it writes each as it happens. Reading that stream while the tests are still
/// running is what lets a mutant cost "time until something notices" instead of "time for
/// the whole suite" - measured on a suite holding a four-second test, the first failure
/// arrived in hundredths of a second.
///
/// Two details make it work rather than hang.
///
/// The read end is opened non-blocking, because opening a pipe for reading otherwise waits
/// for a writer - and a child that fails to start is precisely the case where no writer
/// ever arrives. The flag is cleared immediately afterwards so the reads themselves block
/// rather than spin.
///
/// A write end is held open here as well, and never written to. A pipe reports end-of-file
/// when its *last* writer closes, so without this the reader would see the stream end in
/// the gap before the child opens its own. Closing this end is how the reader is told the
/// child has gone, which makes the end of the stream something this code decides rather
/// than something it races against.
public final class EventPipe: Sendable {

    /// Where the pipe is, for handing to the child.
    public let path: String

    private let readEnd: Int32
    private let writeEnd: Mutex<Int32>

    /// Creates a named pipe at `path`.
    ///
    /// Returns nothing if the pipe could not be made or opened: a run that cannot watch its
    /// tests is a run that has to fall back to waiting for them, and that is a decision for
    /// the caller rather than a reason to fail.
    public init?(path: String) {
        self.path = path
        unsafe unlink(path)
        guard unsafe mkfifo(path, 0o600) == 0 else { return nil }

        let reader = unsafe open(path, O_RDONLY | O_NONBLOCK)
        guard reader >= 0 else {
            unsafe unlink(path)
            return nil
        }
        // Blocking reads from here on: the open was the only part that needed to not wait.
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) & ~O_NONBLOCK)

        let writer = unsafe open(path, O_WRONLY)
        guard writer >= 0 else {
            _ = Darwin.close(reader)
            unsafe unlink(path)
            return nil
        }
        readEnd = reader
        writeEnd = Mutex(writer)
    }

    /// Tells the reader that nothing more is coming.
    ///
    /// Called when the child has gone. Idempotent, because it is called from the ordinary
    /// path and from the failure path and those can both happen.
    public func finish() {
        writeEnd.withLock { descriptor in
            guard descriptor >= 0 else { return }
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// Removes the pipe and lets go of both ends.
    ///
    /// Not called `close`: a method by that name would shadow the system call this type is
    /// built on, inside the one type where that mistake would be hardest to see.
    public func discard() {
        finish()
        _ = Darwin.close(readEnd)
        unsafe unlink(path)
    }

    /// Reads lines as they arrive, until `handle` says stop or the writers are done.
    ///
    /// Off the cooperative pool, on a queue of its own: this blocks in `read`, and a
    /// blocking call on a cooperative thread costs the process a thread it may need to make
    /// progress with - including, when enough mutants run at once, the progress that would
    /// have ended this very read.
    public func lines(_ handle: @escaping @Sendable (String) -> Bool) async {
        let descriptor = readEnd
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var pending: [UInt8] = []
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                reading: while true {
                    // Both spellings: 6.4 calls a marker on `withUnsafeMutableBytes`
                    // unnecessary and 6.3 requires it, and `-warnings-as-errors` makes
                    // either disagreement a build failure. Same condition as the runtime
                    // this tool generates, for the same reason.
                    #if compiler(>=6.4)
                    let count = buffer.withUnsafeMutableBytes {
                        unsafe read(descriptor, $0.baseAddress, $0.count)
                    }
                    #else
                    let count = unsafe buffer.withUnsafeMutableBytes {
                        unsafe read(descriptor, $0.baseAddress, $0.count)
                    }
                    #endif
                    guard count > 0 else { break }
                    for byte in buffer[0..<count] {
                        guard byte == UInt8(ascii: "\n") else {
                            pending.append(byte)
                            continue
                        }
                        let line = String(decoding: pending, as: UTF8.self)
                        pending.removeAll(keepingCapacity: true)
                        guard handle(line) else { break reading }
                    }
                }
                // Whatever was written without a closing newline is a line the writer was
                // in the middle of when it was killed. It is handed over as it stands; a
                // half-written line is refused by the reader of it, not hidden here.
                if !pending.isEmpty { _ = handle(String(decoding: pending, as: UTF8.self)) }
                continuation.resume()
            }
        }
    }
}
