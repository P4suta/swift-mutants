// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Walking the survivors of a finished run.
///
/// A run prints its survivors and stops there, which is right for a log and wrong for the
/// half hour afterwards: the work is one mutant at a time, and `explain <id>` means copying
/// an identity out of a scrollback for each one. This is the same list with somewhere to
/// stand in it.
///
/// A value the whole way: keys in, state out, frames from state. Nothing here reads a
/// terminal or writes to one, so every way of getting lost in a list is something a test
/// can put it in rather than something somebody has to try.
public struct Browser: Sendable {

    /// One survivor, as much of it as a list and a page need.
    ///
    /// Flattened from the report by whoever built this rather than carried as a report row,
    /// because a browser that knew about reports would be a browser that could not show
    /// anything else - and because everything here is then a string a test can assert on.
    public struct Row: Sendable, Hashable {

        /// The mutant's full identity, for somebody who wants to type it somewhere.
        public let identity: String

        /// Where it is, in the words an editor takes.
        public let place: String

        /// Which rule made it.
        public let rule: String

        /// What it changed.
        public let change: String

        /// Everything known about it, which is what opening it shows.
        public let story: [String]

        /// Records one survivor.
        public init(identity: String, place: String, rule: String, change: String, story: [String])
        {
            self.identity = identity
            self.place = place
            self.rule = rule
            self.change = change
            self.story = story
        }
    }

    /// What marks the row somebody is standing on.
    ///
    /// A list with nothing marked is a list where the arrow keys appear to do nothing.
    public static let marker = ">"

    /// The survivors, in the order the run found them.
    public let rows: [Row]

    /// Which one somebody is standing on.
    public private(set) var selected = 0

    /// Whether the one they are standing on is open.
    public private(set) var isShowingOne = false

    /// Whether they are done.
    public private(set) var isFinished = false

    /// Starts on the first of these.
    public init(rows: [Row]) {
        self.rows = rows
    }

    /// The same browser, after one keypress.
    ///
    /// Stops at the ends rather than wrapping. A list that jumped from the last row to the
    /// first is a list somebody loses their place in, and this one is a list of things to
    /// fix.
    public func after(_ key: Key) -> Self {
        var next = self
        switch key {
        case .down:
            next.selected = min(selected + 1, max(0, rows.count - 1))
        case .up:
            next.selected = max(0, selected - 1)
        case .enter:
            next.isShowingOne = !isShowingOne && !rows.isEmpty
        case .quit:
            // Closing the one that is open is not leaving. Somebody who opened a mutant and
            // pressed `q` means "back to the list" about as often as they mean "I am done",
            // and going back is the one that loses nothing.
            if isShowingOne {
                next.isShowingOne = false
            } else {
                next.isFinished = true
            }
        }
        return next
    }

    /// What to draw, in a terminal this size.
    public func frame(width: Int, height: Int) -> [String] {
        let lines =
            isShowingOne && rows.indices.contains(selected)
            ? page(rows[selected]) : list(height: height - 1)
        return (lines + [Self.help]).suffix(max(1, height))
            .map { Self.cut($0, to: max(1, width)) }
    }

    /// Which keys do something, because a person who has to guess will press `q`.
    private static let help = "  up/down or k/j  •  enter opens  •  q goes back"

    /// The list, scrolled so that the row somebody is standing on is on it.
    ///
    /// Otherwise the twentieth row is somewhere nobody can see and the arrow keys stop
    /// meaning anything.
    private func list(height: Int) -> [String] {
        guard !rows.isEmpty else { return ["nothing survived this run."] }
        let room = max(1, height)
        let first = max(0, min(selected - room / 2, rows.count - room))
        return rows[first..<min(first + room, rows.count)].enumerated().map { offset, row in
            let here = first + offset == selected
            return "\(here ? Self.marker : " ") \(row.place)  \(row.rule)  \(row.change)"
        }
    }

    /// Everything known about the one that is open.
    ///
    /// There is always one: ``isShowingOne`` is set only by ``after(_:)``, which refuses an
    /// empty list, and ``selected`` never leaves the rows. A guard for a case that cannot
    /// arise would be a second thing to keep true.
    private func page(_ row: Row) -> [String] {
        return ["\(row.place)  \(row.rule)", "  \(row.change)", "  \(row.identity)", ""]
            + row.story
    }

    /// One line, cut rather than wrapped, for the reason a frame's height is fixed.
    private static func cut(_ line: String, to width: Int) -> String {
        guard line.count > width else { return line }
        guard width > 1 else { return String(line.prefix(width)) }
        return String(line.prefix(width - 1)) + "…"
    }
}
