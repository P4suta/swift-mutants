// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsTUI

/// Walking the survivors of a finished run.
///
/// A run prints its survivors and stops there, which is right for a log and wrong for the
/// half hour afterwards: the work is one mutant at a time, and `explain <id>` means copying
/// an identity out of a scrollback for each one. This is the same list with somewhere to
/// stand in it.
///
/// A value, and a value the whole way: keys in, state out, frames from state. Nothing here
/// reads a terminal, so every way of getting lost in a list is something a test can put it
/// in rather than something somebody has to try.
@Suite("Walking a list of survivors")
struct BrowserTests {

    static func rows(_ count: Int) -> [Browser.Row] {
        (0..<count).map {
            Browser.Row(
                identity: String(repeating: "\($0 % 10)", count: 64),
                place: "Sources/A.swift:\($0 + 1):1",
                rule: "lt-to-le@1",
                change: "<  ->  <=",
                story: ["nothing reached this", "line \($0)"]
            )
        }
    }

    static func browser(_ count: Int = 5) -> Browser {
        Browser(rows: Self.rows(count))
    }

    @Test("starts on the first one")
    func startsAtTheTop() {
        #expect(Self.browser().selected == 0)
    }

    @Test("moves down and back up", arguments: [Key.down, .up])
    func moves(_ key: Key) {
        let moved = Self.browser().after(.down).after(.down)
        #expect(moved.selected == 2)
        #expect(moved.after(key).selected == (key == .down ? 3 : 1))
    }

    /// Stops rather than wrapping. A list that jumped from the last row to the first is a
    /// list somebody loses their place in, and this one is a list of things to fix.
    @Test("stops at the ends rather than wrapping")
    func stopsAtTheEnds() {
        var browser = Self.browser(3)
        for _ in 0..<10 { browser = browser.after(.down) }
        #expect(browser.selected == 2)
        for _ in 0..<10 { browser = browser.after(.up) }
        #expect(browser.selected == 0)
    }

    /// An empty list is a run in which nothing survived, and moving about in it must not be
    /// a way to ask for row minus one.
    @Test("holds still when there is nothing to walk")
    func emptyList() {
        let empty = Browser(rows: [])
        #expect(empty.after(.down).selected == 0)
        #expect(empty.after(.up).selected == 0)
        #expect(!empty.frame(width: 60, height: 10).isEmpty)
        // And there is nothing to open, so opening does nothing rather than opening a page
        // about a row that is not there.
        #expect(!empty.after(.enter).isShowingOne)
        #expect(!empty.after(.enter).frame(width: 60, height: 10).isEmpty)
    }

    @Test("opens one and closes it again")
    func opensAndCloses() {
        let opened = Self.browser().after(.enter)
        #expect(opened.isShowingOne)
        #expect(!opened.after(.enter).isShowingOne)
    }

    /// The thing somebody opened it for.
    @Test("says everything about the one it opened")
    func showsTheStory() {
        let said = Self.browser().after(.down).after(.enter).frame(width: 80, height: 20)
        #expect(said.contains { $0.contains("Sources/A.swift:2:1") })
        #expect(said.contains { $0.contains("line 1") })
    }

    @Test("stops when it is told to")
    func quits() {
        #expect(!Self.browser().isFinished)
        #expect(Self.browser().after(.quit).isFinished)
    }

    /// Closing the one that is open is not leaving. Somebody who opened a mutant and presses
    /// `q` means "back to the list" about as often as they mean "I am done", and the one
    /// that loses nothing is going back.
    @Test("goes back to the list before it leaves")
    func quitClosesFirst() {
        let opened = Self.browser().after(.enter)
        #expect(!opened.after(.quit).isFinished)
        #expect(!opened.after(.quit).isShowingOne)
        #expect(opened.after(.quit).after(.quit).isFinished)
    }

    // MARK: - frames

    @Test("draws every line inside the width it was given", arguments: [20, 40, 100])
    func insideTheWidth(_ width: Int) {
        let frame = Self.browser(40).after(.enter).frame(width: width, height: 12)
        #expect(frame.allSatisfy { $0.count <= width })
    }

    @Test("draws no more lines than the height it was given", arguments: [3, 10, 40])
    func insideTheHeight(_ height: Int) {
        #expect(Self.browser(200).frame(width: 80, height: height).count <= height)
    }

    /// An opened mutant can have more to say than the terminal has room for, and the page
    /// is bounded for the same reason the list is: a frame taller than the screen scrolls
    /// its own top away and takes whatever was above it with it.
    @Test("bounds an opened mutant that has more to say than there is room for")
    func longStoryIsBounded() {
        let long = Browser.Row(
            identity: String(repeating: "a", count: 64),
            place: "Sources/A.swift:1:1",
            rule: "lt-to-le@1",
            change: "<  ->  <=",
            story: (0..<200).map { "line \($0)" }
        )
        #expect(Browser(rows: [long]).after(.enter).frame(width: 80, height: 8).count == 8)
    }

    /// A list longer than the screen scrolls to keep the selection visible. Otherwise the
    /// twentieth row is somewhere nobody can see, and the arrow keys stop meaning anything.
    @Test("keeps the one that is selected on the screen")
    func keepsTheSelectionVisible() {
        var browser = Self.browser(200)
        for _ in 0..<80 { browser = browser.after(.down) }
        let frame = browser.frame(width: 80, height: 10).joined(separator: "\n")
        #expect(frame.contains("Sources/A.swift:81:1"))
    }

    /// And it marks it, because a list with nothing marked is a list where the arrow keys
    /// appear to do nothing.
    @Test("marks the one that is selected")
    func marksTheSelection() {
        let frame = Self.browser(5).after(.down).frame(width: 80, height: 10)
        let marked = frame.filter { $0.hasPrefix(Browser.marker) }
        #expect(marked.count == 1)
        #expect(marked.first?.contains("Sources/A.swift:2:1") == true)
    }

    /// Says which keys do something, because a person who has to guess will press `q`.
    @Test("says what the keys do")
    func saysTheKeys() {
        let frame = Self.browser().frame(width: 80, height: 10).joined(separator: "\n")
        #expect(frame.contains("q"))
    }
}
