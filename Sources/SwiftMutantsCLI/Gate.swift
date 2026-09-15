// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsEngine

/// What a finished run exits with.
///
/// The number is the only part of a run a build system reads, so what it means is fixed
/// rather than incidental, and it is decided here rather than at the bottom of the command
/// that printed the report - a decision spread across a function that also writes files is
/// a decision nobody can test.
///
/// - Zero: this answered the question it was asked. Finding survivors is answering.
/// - One: a gate somebody asked for, and nothing else. A tool that exited non-zero for
///   answering is a tool people stop running, so this is never the default.
/// - Two: this tool or this configuration is wrong. Not reachable by having a low score,
///   because a build that cannot tell "your tests are thin" from "your configuration is
///   lying to me" cannot act on either.
enum Gate {

    /// The survivors a gate is about.
    ///
    /// Not the ones somebody already wrote down. A project that could not both use
    /// `--strict` and account for a mutant nothing can catch would have to choose between
    /// the gate and the truth, and expectations exist precisely so it does not have to.
    static func survivors(of summary: RunSummary) -> Int {
        max(0, summary.survived - summary.expectedSurvivors)
    }

    /// What to exit with, or nothing to exit normally.
    ///
    /// Two beats one when both are true. A run that is over the gate *and* wrong about its
    /// configuration has one thing to fix first, and exiting `1` would send somebody to
    /// write tests for a mutant whose identity no longer exists.
    static func exitCode(
        survivors: Int,
        expectations: Expectations.Verdict,
        unanchored: [UnanchoredMutant] = [],
        strict: Bool
    ) -> Int32? {
        // A row whose anchor has moved is a measurement silently not taken, which is the
        // same news as an expectation naming a mutant that no longer exists - and the same
        // exit, because the alternative is somebody believing they have coverage they do
        // not, about the code they just changed.
        guard expectations.isSatisfied, unanchored.isEmpty else { return 2 }
        return strict && survivors > 0 ? 1 : nil
    }

    /// How the process should leave when a run threw before it had an answer.
    ///
    /// Two, and never one. One means "a gate you asked for was not met", and the only way
    /// to act on that is to write a test or delete a line. A run that never got as far as
    /// measuring has nothing to say about anybody's tests, and sending somebody to look
    /// for a hole that may not exist is the worst thing this number can do.
    ///
    /// It exited `1` until this existed, because a thrown error reaches the argument
    /// parser and the argument parser has one number for every error it does not
    /// recognise. Measured rather than assumed: `run` against a directory with no package
    /// in it exited `1`, which is what `--strict` uses for a mutant the tests let through.
    ///
    /// The message comes back with the code rather than being printed here, so that what
    /// stopped the run is part of the value and a test can hold it. A number on its own
    /// leaves somebody with nothing to do.
    static func unfinished(_ error: any Error) -> (said: String, code: Int32) {
        ("Error: \(error)", 2)
    }
}
