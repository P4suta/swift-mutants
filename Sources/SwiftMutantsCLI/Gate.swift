// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
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
        strict: Bool,
        settings: Configuration.Policy = Configuration.Policy(),
        scoring fraction: Double? = nil
    ) -> Int32? {
        // A row whose anchor has moved is a measurement silently not taken, which is the
        // same news as an expectation naming a mutant that no longer exists - and the same
        // exit, because the alternative is somebody believing they have coverage they do
        // not, about the code they just changed.
        guard expectations.isSatisfied, unanchored.isEmpty else { return 2 }
        // Either source. A flag is what somebody decided just now and a file is what they
        // decided once, and both are somebody asking for the gate; an absent `--strict` is
        // not a decision at all, because a flag whose absence is `false` cannot say "off".
        //
        // The file's copy was read, validated and stored and then asked by nothing, so a
        // project that wrote `strict = true` and wired their build to this got a gate that
        // could not fail - and no way to discover it.
        if (strict || settings.strict) && survivors > 0 { return 1 }
        return Self.floor(settings.minimumScore, against: fraction)
    }

    /// What a score below the floor a project set exits with.
    ///
    /// A floor of zero is the default, so it is not a gate: every score is at or above it
    /// and treating it as one would gate on a setting nobody wrote.
    ///
    /// No score at all is not a score below a floor. It means the denominator was empty -
    /// nothing was measured - and exiting `1` would send somebody to write tests for a hole
    /// nobody has shown exists. Two, because a gate that could not be evaluated is a fact
    /// about this run rather than about their tests, which is exactly the line between the
    /// two numbers.
    ///
    /// The two are in different units and always have been: a score is a fraction, and
    /// `minimum_score = 80` is a percentage, because that is how everybody writes a
    /// threshold down. Comparing them as they arrive gates every run that asked for a
    /// floor, whatever it scored - which is why the conversion is here, in the one place
    /// that knows both, rather than at a call site that would have to remember.
    private static func floor(_ percent: Int, against fraction: Double?) -> Int32? {
        guard percent > 0 else { return nil }
        guard let fraction else { return 2 }
        return fraction < Double(percent) / 100 ? 1 : nil
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
