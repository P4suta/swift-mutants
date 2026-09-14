// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// What a run looks like while it is happening.
///
/// A mutation run takes long enough that somebody watching a silent terminal starts
/// wondering whether it has hung. The lines a run prints answer that; a screen that redraws
/// answers it better, because the counts move and there is one place to look.
///
/// A frame is a value and nothing here can write to a terminal. That is what makes it
/// testable, and it is what keeps the drawing honest: a frame is a fixed number of lines of
/// bounded width, so the thing that redraws knows exactly how far to move the cursor. A
/// frame that wrapped or changed height would leave the cursor somewhere the redraw does
/// not expect, and the screen would walk down the terminal one run at a time.
public struct Dashboard: Sendable {

    /// How far through a run is, as far as anybody watching needs to know.
    public struct State: Sendable, Hashable {

        /// What it is doing.
        public let phase: String

        /// How many mutants are finished.
        public let done: Int

        /// How many there are, or nothing yet.
        public let total: Int

        /// How many the tests caught.
        public let killed: Int

        /// How many they did not.
        public let survived: Int

        /// Records how far through a run is.
        public init(phase: String, done: Int, total: Int, killed: Int, survived: Int) {
            self.phase = phase
            self.done = done
            self.total = total
            self.killed = killed
            self.survived = survived
        }
    }

    /// The character a filled part of the bar is drawn with.
    public static let filled: Character = "#"

    /// And an unfilled one.
    public static let empty: Character = "-"

    /// How many characters of bar fit in a terminal this wide.
    ///
    /// A function of the terminal and nothing else, which is why the bar is on a line of
    /// its own: sharing a line with the counts would make its width depend on how many
    /// mutants there are, and a bar that changed width as the numbers grew would be a bar
    /// nobody could read the position of.
    ///
    /// Nought in a terminal too narrow to draw a useful one in, where the counts are what
    /// somebody is reading anyway. A bar three characters wide says nothing and costs the
    /// line the counts would have gone on.
    public static func width(inside terminal: Int) -> Int {
        let room = min(60, terminal - Self.brackets)
        return room < Self.leastUseful ? 0 : room
    }

    /// What the bar's brackets cost.
    private static let brackets = 2

    /// The narrowest bar worth drawing, in characters.
    ///
    /// Below this a bar cannot show a position: at four characters every run is empty,
    /// a quarter, half, three quarters or full, which is less than the counts already say.
    private static let leastUseful = 8

    /// How wide the terminal is.
    private let width: Int

    /// Draws frames for a terminal this wide.
    public init(width: Int) {
        self.width = max(1, width)
    }

    /// How many lines a frame has, whatever is in it.
    ///
    /// The same number every time, so the thing redrawing always moves the cursor the same
    /// distance. A frame that grew by a line would leave the one before it on the screen,
    /// and the screen would walk down the terminal one phase at a time.
    public static let height = 3

    /// One frame, as lines.
    public func frame(of state: State) -> [String] {
        [Self.cut(state.phase, to: width), bar(of: state), Self.cut(counts(of: state), to: width)]
    }

    /// The bar, or an empty line before there is anything to count.
    ///
    /// A bar drawn from a total of nothing is either empty or full and means neither, so
    /// there is none - and the line stays, because the height does.
    private func bar(of state: State) -> String {
        let room = Self.width(inside: width)
        guard state.total > 0, room > 0 else { return "" }
        let filled = room * state.done / state.total
        return "["
            + String(repeating: String(Self.filled), count: filled)
            + String(repeating: String(Self.empty), count: room - filled)
            + "]"
    }

    /// How far through, and the two counts somebody is watching.
    private func counts(of state: State) -> String {
        "\(state.done)/\(state.total)"
            + "  \(state.killed) killed  \(state.survived) survived"
    }

    /// One line, cut rather than wrapped.
    ///
    /// Cut, because a frame of known height is what the redraw rests on and a wrapped line
    /// is a frame one line taller than the thing drawing it believes.
    private static func cut(_ line: String, to width: Int) -> String {
        guard line.count > width else { return line }
        guard width > 1 else { return String(line.prefix(width)) }
        return String(line.prefix(width - 1)) + "…"
    }
}
