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
        let restore = try raw()
        defer { restore() }

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
    private static func raw() throws -> @Sendable () -> Void {
        var original = termios()
        guard unsafe tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw TerminalError(description: "this is not a terminal this tool can read keys from")
        }
        var mode = original
        unsafe cfmakeraw(&mode)
        // Return is still a keypress, and Control-C should still stop the process rather
        // than arriving as a byte nobody handles.
        mode.c_lflag |= UInt(ISIG)
        guard unsafe tcsetattr(STDIN_FILENO, TCSANOW, &mode) == 0 else {
            throw TerminalError(description: "this terminal would not let its mode be changed")
        }
        let kept = original
        return { [kept] in
            var restoring = kept
            _ = unsafe tcsetattr(STDIN_FILENO, TCSANOW, &restoring)
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
