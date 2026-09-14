// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

private import Synchronization

/// Redrawing a frame in place.
///
/// The whole trick is cursor movement and the whole risk is getting the distance wrong: a
/// screen that moves up one line too few leaves a stripe of old frames down the terminal,
/// and one that moves too many overwrites whatever the run printed before it started. That
/// is why a frame is always the same height - this moves by exactly that number and never
/// has to work out how tall the last one was.
///
/// The bytes are handed to a sink rather than written, so the arithmetic is something a
/// test can hold rather than something somebody has to watch.
public final class Screen: Sendable {

    /// Move the cursor up this many lines.
    ///
    /// A whole sequence rather than the prefix it is built from, because the prefix is also
    /// the prefix of ``clearLine`` - and a caller checking for one would find the other.
    public static func up(_ lines: Int) -> String { "\u{1b}[\(lines)A" }

    /// Clear from the cursor to the end of the line.
    ///
    /// Without it a shorter line leaves the tail of the longer one it replaced, and a count
    /// going from 100 to 99 reads as 990.
    public static let clearLine = "\u{1b}[K"

    private let height: Int
    private let write: @Sendable (String) -> Void
    private let drawn = Mutex(false)

    /// Draws frames of a fixed height through `write`.
    public init(height: Int, write: @escaping @Sendable (String) -> Void) {
        self.height = max(0, height)
        self.write = write
    }

    /// Draws one frame where the last one was.
    public func draw(_ lines: [String]) {
        let moveBack = drawn.withLock { drawn -> String in
            defer { drawn = true }
            return drawn && height > 0 ? Self.up(height) : ""
        }
        write(moveBack + lines.map { "\(Self.clearLine)\($0)" }.joined(separator: "\n") + "\n")
    }

    /// Leaves the last frame on the screen and moves past it.
    ///
    /// Whatever a run drew stays there, and what comes next starts on a line of its own: a
    /// summary printed onto the last frame would be a summary with a progress bar through
    /// it. Nothing at all if nothing was drawn, and nothing twice if it is told twice - a
    /// run that fails on its way out of a finished run should not leave two gaps.
    public func finish() {
        let hadDrawn = drawn.withLock { drawn -> Bool in
            defer { drawn = false }
            return drawn
        }
        guard hadDrawn else { return }
        write("\n")
    }
}
