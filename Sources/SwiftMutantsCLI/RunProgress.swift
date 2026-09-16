// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConsole
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
import SwiftMutantsTUI
import Synchronization

/// How far through the mutants a run is.
///
/// A line per mutant would bury the handful a person can act on, and no line at all leaves
/// somebody watching a silent terminal for half an hour wondering whether it has hung -
/// which is what the first run of this tool against this repository felt like.
///
/// Counts rather than names, because results arrive from whichever worker finished first. A
/// line naming mutants in that order would differ between two runs of the same package, and
/// the one thing a report must not do is change shape because a machine was busy.
struct RunCounter {

    /// How often to say something, in mutants.
    ///
    /// Often enough to show movement on a small package, rare enough not to scroll a large
    /// one away.
    static let every = 25

    private(set) var done = 0
    private(set) var killed = 0
    private(set) var survived = 0

    /// How many mutants this run is about.
    ///
    /// The whole catalogue, not the part of it that has to be executed. Every mutant is
    /// finished whether it ran or was answered from an earlier run, so a total that counted
    /// only the ones that ran would be counted past - and a warm run would say `676/0`.
    private(set) var total = 0

    /// Whether the catalogue's size is already known.
    ///
    /// `.remembered` carries it and arrives first; `.running` carries only the work left,
    /// which is the whole catalogue exactly when nothing was remembered.
    private var totalIsKnown = false

    /// Takes one stage into account, and says what to print about it, if anything.
    mutating func observe(_ stage: RunStage) -> String? {
        switch stage {
        case .remembered(_, let total):
            self.total = total
            totalIsKnown = true
            return nil
        case .running(let total, _):
            if !totalIsKnown { self.total = total }
            return nil
        case .finished(let result):
            return count(result)
        default:
            return nil
        }
    }

    /// Counts one answer, and says how it is going every so often.
    private mutating func count(_ result: MutantResult) -> String? {
        done += 1
        if result.verdict.outcome == .killed { killed += 1 }
        if result.verdict.outcome == .survived { survived += 1 }
        guard done.isMultiple(of: Self.every) || done == total else { return nil }
        return "  \(done)/\(total)  \(killed) killed  \(survived) survived"
    }
}

/// Says what a run is doing while it does it.
///
/// One line per phase, and a counter while the mutants run. The counting is a value so that
/// it can be tested without a terminal; this is the part that owns a lock and prints.
final class RunProgress: Sendable {

    private let counter = Mutex(RunCounter())

    /// How much to say.
    private let verbosity: Verbosity

    /// Where the lines go.
    ///
    /// A parameter rather than `print`, because what a run says while it works is a thing
    /// worth testing and a terminal is not a thing a test should need. The default is the
    /// terminal, so nothing at a call site has to say so.
    private let say: @Sendable (String) -> Void

    /// The screen it draws on, when it draws rather than printing lines.
    private let screen: Screen?

    /// What it last knew, so a frame can be drawn from a stage that carries only part of it.
    private let state = Mutex(
        Dashboard.State(phase: "", done: 0, total: 0, killed: 0, survived: 0))

    private let dashboard = Dashboard(width: 72)

    /// Where the drawn frames go.
    ///
    /// Apart from `say`, because the two are different things: a line is a line and a frame
    /// is bytes with cursor movement in them, written without a newline of their own. Both
    /// are parameters, so what a run draws is something a test can hold rather than
    /// something somebody has to watch on a terminal.
    init(
        verbosity: Verbosity = .normal,
        drawing: Bool = false,
        say: @escaping @Sendable (String) -> Void = { print($0) },
        draw: @escaping @Sendable (String) -> Void = { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    ) {
        self.verbosity = verbosity
        self.say = say
        self.screen = drawing ? Screen(height: Dashboard.height, write: draw) : nil
    }

    /// Leaves whatever was drawn on the screen and moves past it.
    ///
    /// Said plainly rather than left to a deinit: the summary is printed right after this,
    /// and a summary painted onto the last frame would be a summary with a progress bar
    /// through it.
    func finish() { screen?.finish() }

    /// Says what phase a run has reached, and how far through the mutants it is.
    ///
    /// Nothing at all when it was told to be quiet: somebody running this in a script wants
    /// the exit code, and a tool that talked through it anyway would be a tool they pipe to
    /// /dev/null - which loses the errors too.
    func report(_ stage: RunStage) {
        let counted = counter.withLock { $0.observe(stage) }
        guard verbosity > .quiet else { return }
        if let screen {
            // News first, and under the frame rather than in it: `finish` leaves the last
            // frame on the screen and starts the next one below, so what a reader has to
            // keep is not wiped off a second later by the phase that follows it.
            if let news = Narration.news(for: stage) {
                screen.finish()
                say(news)
            }
            screen.draw(dashboard.frame(of: advanced(by: stage)))
            return
        }
        if let counted {
            say(counted)
            return
        }
        if let line = Narration.line(for: stage) { say(line) }
    }

    /// The one line of a stage that belongs in a frame, if it has one.
    ///
    /// Nothing for a stage whose message is news: that has already been said under the
    /// frame, and a frame holds one line, so drawing it would be the same words twice with
    /// all but the first line of them missing.
    private static func headline(for stage: RunStage) -> String? {
        guard Narration.news(for: stage) == nil else { return nil }
        return Narration.line(for: stage)?.trimmingCharacters(in: .whitespaces)
    }

    /// What is known after this stage.
    ///
    /// A stage carries part of it - a phase line carries no counts, a finished mutant
    /// carries no phase - so the rest is whatever it was. A frame built from one stage
    /// alone would blank the half of itself that stage did not mention, and a bar that
    /// vanished every time a phase line arrived would be worse than no bar.
    private func advanced(by stage: RunStage) -> Dashboard.State {
        let counts = counter.withLock { ($0.done, $0.total, $0.killed, $0.survived) }
        return state.withLock { state in
            state = Dashboard.State(
                phase: Self.headline(for: stage) ?? state.phase,
                done: counts.0,
                total: counts.1,
                killed: counts.2,
                survived: counts.3
            )
            return state
        }
    }
}
