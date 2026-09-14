// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTUI

/// A terminal handed over to a browser, and given back.
///
/// The thin part, deliberately. Everything about what to draw and what a key means is a
/// value tested without a terminal; this is the shell that reads bytes, and the one thing it
/// has to get right is giving the terminal back - a process that exits without restoring the
/// mode leaves a shell with no echo, which somebody then has to `reset` blind.
enum Terminal {

    /// Walks a browser until it says it is done.
    static func walk(_ start: Browser) throws {
        let restore = try raw(STDIN_FILENO)
        defer { restore() }
        // A `defer` does not run when a signal ends the process, and Control-C is how
        // people leave things. Without this, interrupting a browse leaves a shell with no
        // echo and no line editing, which somebody then has to `reset` blind - the exact
        // failure the rest of this file is careful about.
        Self.restoreOnInterrupt()

        var browser = start
        var pending: [UInt8] = []
        let size = Self.size()
        let screen = Screen(height: size.height) { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        screen.draw(browser.frame(width: size.width, height: size.height))

        while !browser.isFinished {
            guard let read = try? FileHandle.standardInput.read(upToCount: 16), !read.isEmpty
            else { break }
            let (keys, kept) = Key.read(from: pending + Array(read))
            pending = kept
            for key in keys where !browser.isFinished {
                browser = browser.after(key)
            }
            screen.draw(browser.frame(width: size.width, height: size.height))
        }
        screen.finish()
    }

    /// Puts the terminal into raw mode, and hands back what puts it back.
    ///
    /// Raw because a browser reads single keypresses: in the ordinary mode the terminal
    /// holds a line until Return, so an arrow key would do nothing until somebody pressed it.
    /// Takes a descriptor rather than assuming standard input, so that a test can hand it a
    /// terminal of its own: the one thing worth proving here is that what goes in comes back
    /// out, and proving it on the terminal the test is running in would mean breaking it.
    static func raw(_ descriptor: Int32) throws -> @Sendable () -> Void {
        var original = termios()
        guard unsafe tcgetattr(descriptor, &original) == 0 else {
            throw TerminalError(description: "this is not a terminal this tool can read keys from")
        }
        unsafe Self.beforeRaw = original
        var mode = original
        unsafe cfmakeraw(&mode)
        // Return is still a keypress, and Control-C should still stop the process rather
        // than arriving as a byte nobody handles.
        mode.c_lflag |= UInt(ISIG)
        guard unsafe tcsetattr(descriptor, TCSANOW, &mode) == 0 else {
            throw TerminalError(description: "this terminal would not let its mode be changed")
        }
        let kept = original
        return { [kept] in
            var restoring = kept
            _ = unsafe tcsetattr(descriptor, TCSANOW, &restoring)
        }
    }

    /// Whether a descriptor is in the mode this tool puts a terminal into.
    ///
    /// Two things, and the second is the one somebody feels: raw mode is what lets a single
    /// keypress arrive, and echo off is what stops the keypress appearing on the screen. A
    /// shell left in this state shows nothing as you type.
    static func isRaw(_ descriptor: Int32) -> Bool {
        var mode = termios()
        guard unsafe tcgetattr(descriptor, &mode) == 0 else { return false }
        return mode.c_lflag & UInt(ICANON) == 0 && mode.c_lflag & UInt(ECHO) == 0
    }

    /// What the terminal looked like before any of this, for a signal handler to put back.
    ///
    /// A global because that is what a signal handler can reach: it runs outside any call
    /// stack, and the only things it may touch are async-signal-safe. `tcsetattr` is one of
    /// them; allocating, locking or calling Swift runtime machinery is not.
    nonisolated(unsafe) private static var beforeRaw = termios()

    /// Puts the terminal back and then dies of the signal it was given.
    ///
    /// Re-raised rather than exited, so that whoever started this sees a process that was
    /// interrupted rather than one that chose to stop - a shell script reading `$?` is
    /// entitled to tell those apart.
    private static func restoreOnInterrupt() {
        for interrupting in [SIGINT, SIGTERM] {
            Darwin.signal(
                interrupting,
                { received in
                    // The only call here that is not async-signal-safe would be one that
                    // allocated or locked, and none of these do.
                    _ = unsafe tcsetattr(STDIN_FILENO, TCSANOW, &Self.beforeRaw)
                    Darwin.signal(received, SIG_DFL)
                    raise(received)
                })
        }
    }

    /// How big the terminal is, with a shape to fall back on when it will not say.
    static func size() -> (width: Int, height: Int) {
        var window = winsize()
        guard unsafe ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &window) == 0,
            window.ws_col > 0, window.ws_row > 0
        else {
            return (80, 24)
        }
        return (Int(window.ws_col), Int(window.ws_row))
    }

    /// A terminal that would not do what this needs.
    struct TerminalError: Error, CustomStringConvertible {
        let description: String
    }
}
