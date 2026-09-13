// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import SwiftMutantsRunner

/// Watching a child talk while it is still talking.
///
/// The whole early-kill design rests on this: if the stream only arrived at the end, a
/// mutant would cost what the suite costs, and stopping at the first failure would save
/// nothing. These tests hold the two ways it could quietly stop working - a read that waits
/// for the end, and a reader that sees the end too early.
@Suite("Event pipe")
struct EventPipeTests {

    static func path() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-pipe-\(UUID().uuidString)").path
    }

    @Test("hands over each line as it is written")
    func streams() async throws {
        let pipe = try #require(EventPipe(path: Self.path()))
        defer { pipe.discard() }

        let seen = Mutex<[String]>([])
        let reading = Task {
            await pipe.lines { line in
                seen.withLock { $0.append(line) }; return true
            }
        }

        let writer = try #require(FileHandle(forWritingAtPath: pipe.path))
        try writer.write(contentsOf: Data("one\ntwo\n".utf8))
        try writer.write(contentsOf: Data("three\n".utf8))
        try writer.close()
        pipe.finish()
        await reading.value

        #expect(seen.withLock { $0 } == ["one", "two", "three"])
    }

    /// The point of the exercise: the reader stops the moment it has its answer, without
    /// waiting for whatever the writer was going to say next.
    @Test("stops reading when the handler says so")
    func stopsEarly() async throws {
        let pipe = try #require(EventPipe(path: Self.path()))
        defer { pipe.discard() }

        let seen = Mutex<[String]>([])
        let reading = Task {
            await pipe.lines { line in
                seen.withLock { $0.append(line) }
                return line != "stop"
            }
        }

        let writer = try #require(FileHandle(forWritingAtPath: pipe.path))
        try writer.write(contentsOf: Data("one\nstop\nthree\n".utf8))
        await reading.value
        try? writer.close()

        #expect(seen.withLock { $0 } == ["one", "stop"])
    }

    /// A child that never writes anything must not leave the reader waiting for ever. The
    /// held-open write end is what makes the end of the stream this tool's decision.
    @Test("ends when told the writers are done, even with nothing written")
    func endsOnFinish() async throws {
        let pipe = try #require(EventPipe(path: Self.path()))
        defer { pipe.discard() }

        let reading = Task { await pipe.lines { _ in true } }
        pipe.finish()
        await reading.value
    }

    /// A writer killed mid-line leaves a fragment. It is handed over as it stands, because
    /// deciding it is not an event belongs to the thing that reads events, not here.
    @Test("hands over a line the writer did not finish")
    func unterminatedLine() async throws {
        let pipe = try #require(EventPipe(path: Self.path()))
        defer { pipe.discard() }

        let seen = Mutex<[String]>([])
        let reading = Task {
            await pipe.lines { line in
                seen.withLock { $0.append(line) }; return true
            }
        }

        let writer = try #require(FileHandle(forWritingAtPath: pipe.path))
        try writer.write(contentsOf: Data("done\nhalf-writ".utf8))
        try writer.close()
        pipe.finish()
        await reading.value

        #expect(seen.withLock { $0 } == ["done", "half-writ"])
    }

    /// The gap between "start watching" and "the child opens its end".
    ///
    /// A pipe reports end-of-file when its last writer closes, and at this moment it has
    /// never had one - so a reader that simply read would be told the stream was over
    /// before it began, and every mutant would come back as a suite that said nothing.
    /// Holding a write end here is what closes that gap, and reading blocking rather than
    /// non-blocking is what stops the first empty read from ending it anyway. Both are
    /// races, so both need a test that loses them deliberately.
    @Test("waits for a writer that has not arrived yet")
    func waitsForALateWriter() async throws {
        let pipe = try #require(EventPipe(path: Self.path()))
        defer { pipe.discard() }

        let seen = Mutex<[String]>([])
        let reading = Task {
            await pipe.lines { line in
                seen.withLock { $0.append(line) }
                return true
            }
        }

        // Long enough that a reader which ended at the first empty read has certainly
        // ended, and short enough to stay a test.
        try await Task.sleep(for: .milliseconds(250))
        let writer = try #require(FileHandle(forWritingAtPath: pipe.path))
        try writer.write(contentsOf: Data("late\n".utf8))
        try writer.close()
        pipe.finish()
        await reading.value

        #expect(seen.withLock { $0 } == ["late"])
    }

    /// Opening a pipe for reading normally waits for a writer, and a child that failed to
    /// start is exactly when none arrives. Creating the pipe must return rather than wait.
    @Test("is ready before anything opens the other end")
    func openDoesNotWait() throws {
        let pipe = try #require(EventPipe(path: Self.path()))
        defer { pipe.discard() }
        #expect(FileManager.default.fileExists(atPath: pipe.path))
    }

    @Test("says so when it cannot make a pipe")
    func refusesAnImpossiblePath() {
        #expect(EventPipe(path: "/no/such/directory/anywhere/events.fifo") == nil)
    }

    /// Called from the ordinary path and the failure path, which can both happen.
    @Test("can be told the writers are done more than once")
    func finishIsIdempotent() throws {
        let pipe = try #require(EventPipe(path: Self.path()))
        defer { pipe.discard() }
        pipe.finish()
        pipe.finish()
    }
}
