// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConsole
import SwiftMutantsCore
import SwiftMutantsEngine
import SwiftMutantsExecute
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

    init(verbosity: Verbosity = .normal, say: @escaping @Sendable (String) -> Void = { print($0) })
    {
        self.verbosity = verbosity
        self.say = say
    }

    /// Says what phase a run has reached, and how far through the mutants it is.
    ///
    /// Nothing at all when it was told to be quiet: somebody running this in a script wants
    /// the exit code, and a tool that talked through it anyway would be a tool they pipe to
    /// /dev/null - which loses the errors too.
    func report(_ stage: RunStage) {
        let counted = counter.withLock { $0.observe(stage) }
        guard verbosity > .quiet else { return }
        if let counted {
            say(counted)
            return
        }
        if let line = Narration.line(for: stage) { say(line) }
    }
}
