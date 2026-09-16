// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsTUI

/// What a run looks like while it is happening.
///
/// A mutation run takes long enough that somebody watching a silent terminal starts
/// wondering whether it has hung - which is what the first run of this tool against this
/// repository felt like. The lines a run prints answer that, and a screen that redraws
/// answers it better: the counts move, and there is one place to look.
///
/// The frame is a value, and nothing here can write to a terminal. That is what makes any
/// of it testable, and it is also what keeps the drawing honest: a frame is a list of lines
/// of known widths, so the thing that redraws knows exactly how far to move the cursor.
@Suite("What a run looks like while it happens")
struct DashboardTests {

    static func frame(
        _ state: Dashboard.State, width: Int = 60
    ) -> [String] {
        Dashboard(width: width).frame(of: state)
    }

    static var running: Dashboard.State {
        Dashboard.State(
            phase: "running 726 mutants", done: 250, total: 726, killed: 180, survived: 70)
    }

    /// A frame is exactly as tall as the thing redrawing it believes, whatever it is given.
    ///
    /// `cut` bounds the *width* and says why: a wrapped line is a frame one line taller
    /// than the screen's cursor arithmetic assumes, so the screen walks down the terminal
    /// leaving a stripe of old frames. A line that already holds a newline does the same
    /// damage through the door that check does not cover - and one exists, because what a
    /// run has to say is not always one line long.
    @Test("is three lines tall however many the phase has in it")
    func staysThreeLines() {
        let many = Dashboard.State(
            phase: "2 stepped aside\n\nAnything only those cover cannot be caught.",
            done: 1,
            total: 2,
            killed: 1,
            survived: 0
        )
        let drawn = Self.frame(many)
        #expect(drawn.count == 3, "\(drawn)")
        #expect(!drawn.joined().contains("\n"), "\(drawn)")
    }

    @Test("says what it is doing")
    func saysThePhase() {
        #expect(Self.frame(Self.running).contains { $0.contains("running 726 mutants") })
    }

    @Test("says how far through it is")
    func saysHowFar() {
        let said = Self.frame(Self.running).joined(separator: "\n")
        #expect(said.contains("250/726"))
        #expect(said.contains("180 killed"))
        #expect(said.contains("70 survived"))
    }

    /// The bar is the thing somebody glances at, so it has to be the width it was told and
    /// not a character more: a frame that wrapped would leave the cursor somewhere the
    /// redraw does not expect, and the screen would walk down the terminal.
    @Test("draws every line inside the width it was given", arguments: [20, 40, 80, 200])
    func staysInsideTheWidth(_ width: Int) {
        for line in Self.frame(Self.running, width: width) {
            #expect(line.count <= width)
        }
    }

    /// A terminal narrower than the counts is still a terminal. It gets the counts.
    @Test("keeps the counts when there is no room for a bar")
    func countsBeatTheBar() {
        let said = Self.frame(Self.running, width: 24).joined(separator: "\n")
        #expect(said.contains("250/726"))
    }

    /// Proportional to what is done, and never past the end. A bar that could overflow
    /// would be a bar that wraps, and a wrapped frame walks the screen.
    @Test(
        "fills the bar in proportion to what is done",
        arguments: [(0, 100), (1, 100), (50, 100), (99, 100), (100, 100)])
    func barIsProportional(_ done: Int, _ total: Int) {
        let state = Dashboard.State(
            phase: "running", done: done, total: total, killed: 0, survived: 0)
        let bar = Self.frame(state).first { $0.contains("[") && $0.contains("]") }
        let filled = bar?.count { $0 == Dashboard.filled } ?? -1
        let empty = bar?.count { $0 == Dashboard.empty } ?? -1
        #expect(filled >= 0)
        #expect(filled + empty == Dashboard.width(inside: 60))
        #expect(filled == Dashboard.width(inside: 60) * done / total)
    }

    /// A phase before the mutants start has no total, and a bar drawn from a total of
    /// nothing would be a bar that is either empty or full and means neither.
    @Test("draws no bar before there is anything to count")
    func noBarWithoutATotal() {
        let state = Dashboard.State(
            phase: "reading the sources", done: 0, total: 0, killed: 0, survived: 0)
        #expect(!Self.frame(state).contains { $0.contains("[") })
        #expect(Self.frame(state).count == Dashboard.height)
        #expect(Self.frame(state).contains { $0.contains("reading the sources") })
    }

    /// A terminal too narrow to draw a bar in is still a terminal, and the frame it gets
    /// still has to be a frame: the same height, inside the width, and no bar with a
    /// negative number of characters in it.
    @Test("draws a frame in a terminal with no room for a bar", arguments: [1, 2, 3, 5])
    func veryNarrow(_ width: Int) {
        let frame = Self.frame(Self.running, width: width)
        #expect(frame.count == Dashboard.height)
        #expect(frame.allSatisfy { $0.count <= width })
        #expect(!frame.contains { $0.contains("[") })
    }

    /// A phase longer than the terminal is cut rather than wrapped, for the same reason the
    /// bar is: a frame of known height is what the redraw rests on.
    @Test("cuts a phase too long to fit rather than wrapping it")
    func cutsALongPhase() {
        let state = Dashboard.State(
            phase: String(repeating: "x", count: 500), done: 0, total: 0, killed: 0, survived: 0)
        let frame = Self.frame(state, width: 40)
        #expect(frame.allSatisfy { $0.count <= 40 })
        #expect(frame.contains { $0.hasSuffix("…") })
    }

    /// Every frame is the same height, so the redraw always moves the cursor the same
    /// distance. A frame that grew by a line would leave the one before it on the screen.
    @Test("is always the same height")
    func constantHeight() {
        let states = [
            Self.running,
            Dashboard.State(phase: "reading", done: 0, total: 0, killed: 0, survived: 0),
            Dashboard.State(phase: "", done: 726, total: 726, killed: 400, survived: 326),
        ]
        #expect(Set(states.map { Self.frame($0).count }).count == 1)
    }

    /// Nothing but text. Colour and cursor movement belong to the thing that draws, not to
    /// the thing that decides what to say, so a frame is something a test can hold and a
    /// log can keep.
    @Test("puts no escape sequences in a frame")
    func noEscapes() {
        #expect(Self.frame(Self.running).allSatisfy { !$0.contains("\u{1b}") })
    }
}
