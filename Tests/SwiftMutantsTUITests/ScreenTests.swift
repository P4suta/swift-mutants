// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Synchronization
import Testing

@testable import SwiftMutantsTUI

/// Redrawing a frame in place.
///
/// The whole trick is cursor movement, and the whole risk is getting the distance wrong: a
/// screen that moved up one line too few leaves a stripe of old frames down the terminal,
/// and one that moved too many overwrites whatever the run printed before it started.
///
/// So the bytes it writes are a value a test can hold, and the arithmetic is checked rather
/// than watched. Nothing here opens a terminal.
@Suite("Redrawing in place")
struct ScreenTests {

    static func screen() -> (Screen, @Sendable () -> [String]) {
        let written = Mutex<[String]>([])
        let screen = Screen(height: 3) { text in written.withLock { $0.append(text) } }
        return (screen, { written.withLock { $0 } })
    }

    @Test("writes the frame the first time, and moves nothing")
    func firstFrame() {
        let (screen, written) = Self.screen()
        screen.draw(["a", "b", "c"])
        let text = written().joined()
        #expect(text.contains("a"))
        #expect(text.contains("b"))
        #expect(text.contains("c"))
        #expect(!text.contains(Screen.up(3)))
    }

    /// Up by exactly the height, every time after the first. That number is why a frame is
    /// always the same height.
    @Test("moves up by the height of the frame it drew")
    func movesUpTheHeight() {
        let (screen, written) = Self.screen()
        screen.draw(["a", "b", "c"])
        screen.draw(["d", "e", "f"])
        let second = written().last ?? ""
        #expect(second.hasPrefix(Screen.up(3)))
        #expect(second.contains("d"))
        #expect(second.contains("f"))
        // And by the height, not by the number of lines it happens to be handed.
        #expect(!second.contains(Screen.up(2)))
    }

    /// Each line is cleared to the end before the new one is written. Without it a shorter
    /// line leaves the tail of the longer one it replaced, and a count going from 100 to 99
    /// reads as 990.
    @Test("clears each line before writing over it")
    func clearsEachLine() {
        let (screen, written) = Self.screen()
        screen.draw(["aaa", "b", "c"])
        screen.draw(["a", "b", "c"])
        #expect((written().last ?? "").contains(Screen.clearLine))
    }

    /// Whatever is on the screen when a run ends stays there, and what comes next starts on
    /// a line of its own. A summary printed onto the last frame would be a summary with a
    /// progress bar through it.
    @Test("leaves the last frame behind and moves past it")
    func leavesTheLastFrame() {
        let (screen, written) = Self.screen()
        screen.draw(["a", "b", "c"])
        screen.finish()
        #expect((written().last ?? "").hasSuffix("\n"))
        #expect(!(written().last ?? "").contains(Screen.up(3)))
    }

    /// Ending a screen that never drew anything writes nothing. A run that was told to be
    /// quiet, or that failed before the first frame, should not print a stray newline.
    @Test("writes nothing when it never drew")
    func nothingDrawnNothingWritten() {
        let (screen, written) = Self.screen()
        screen.finish()
        #expect(written().isEmpty)
    }

    /// And it is idempotent, because a run that ends twice - an error on the way out of a
    /// finished run - should not leave two gaps.
    @Test("ends once however many times it is told to")
    func endsOnce() {
        let (screen, written) = Self.screen()
        screen.draw(["a", "b", "c"])
        screen.finish()
        screen.finish()
        #expect(written().count == 2)
    }
}
