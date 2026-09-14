// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsCLI

/// Giving a terminal back.
///
/// The one thing this part of `browse` has to get right. A process that leaves a terminal in
/// raw mode leaves a shell that shows nothing as you type and does nothing when you press
/// Return, and the person it happened to has to type `reset` blind to get out of it.
///
/// Proved on a terminal of the test's own rather than on the one the test is running in,
/// because the way to prove it is to break a terminal and then check it came back.
@Suite("Giving a terminal back")
struct TerminalTests {

    /// A terminal nobody is watching, for a test to put into raw mode and out again.
    ///
    /// `posix_openpt` makes a pair; the side this hands back is the one a program would
    /// have as its standard input.
    static func pseudoTerminal() throws -> (primary: Int32, secondary: Int32) {
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(primary >= 0)
        try #require(grantpt(primary) == 0)
        try #require(unlockpt(primary) == 0)
        let name = try #require(unsafe ptsname(primary).map { unsafe String(cString: $0) })
        let secondary = unsafe open(name, O_RDWR | O_NOCTTY)
        try #require(secondary >= 0)
        return (primary, secondary)
    }

    @Test("puts a terminal into raw mode and takes it back out")
    func thereAndBack() throws {
        let pair = try Self.pseudoTerminal()
        defer {
            close(pair.secondary)
            close(pair.primary)
        }
        #expect(!Terminal.isRaw(pair.secondary))

        let restore = try Terminal.raw(pair.secondary)
        #expect(Terminal.isRaw(pair.secondary))

        restore()
        #expect(!Terminal.isRaw(pair.secondary))
    }

    /// Byte for byte, not merely "not raw any more". A terminal handed back with one flag
    /// different is a terminal somebody's next command behaves oddly in, and they will
    /// never connect it to this.
    @Test("hands it back exactly as it was")
    func exactlyAsItWas() throws {
        let pair = try Self.pseudoTerminal()
        defer {
            close(pair.secondary)
            close(pair.primary)
        }
        var before = termios()
        try #require(unsafe tcgetattr(pair.secondary, &before) == 0)

        let restore = try Terminal.raw(pair.secondary)
        restore()

        var after = termios()
        try #require(unsafe tcgetattr(pair.secondary, &after) == 0)
        #expect(before.c_iflag == after.c_iflag)
        #expect(before.c_oflag == after.c_oflag)
        #expect(before.c_cflag == after.c_cflag)
        // Every local flag but `PENDIN`, which the kernel sets by itself and means "there
        // is input waiting to be retyped" rather than anything about how the terminal is
        // configured. Measured: it is the one bit that differs, and it differs whichever
        // way round the modes are set.
        let settings = ~UInt(PENDIN)
        #expect(before.c_lflag & settings == after.c_lflag & settings)
    }

    /// Control-C still stops the process. Without this the signal arrives as a byte nobody
    /// handles, and the only way out of a browse would be to kill it from another terminal.
    @Test("leaves Control-C able to stop the process")
    func interruptStillWorks() throws {
        let pair = try Self.pseudoTerminal()
        defer {
            close(pair.secondary)
            close(pair.primary)
        }
        let restore = try Terminal.raw(pair.secondary)
        defer { restore() }

        var mode = termios()
        try #require(unsafe tcgetattr(pair.secondary, &mode) == 0)
        #expect(mode.c_lflag & UInt(ISIG) != 0)
    }

    /// Something that is not a terminal is said plainly rather than left to fail later: a
    /// browse in a pipe takes a different path entirely, and this is what tells it apart.
    @Test("says so when it was given something that is not a terminal")
    func notATerminal() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-not-a-terminal-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let descriptor = unsafe open(file.path, O_RDWR)
        try #require(descriptor >= 0)
        defer { close(descriptor) }

        #expect(throws: Terminal.TerminalError.self) { try Terminal.raw(descriptor) }
        #expect(!Terminal.isRaw(descriptor))
    }
}
