// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsConfig
public import SwiftMutantsCore
import SwiftMutantsExecute

/// Survivors a project has written down as evidence rather than as gaps.
///
/// Some survivors are not holes. A mutant in code unreachable by construction, or one whose
/// behaviour genuinely cannot be observed, survives every suite anybody writes - and a tool
/// whose list never shrinks below those is a tool whose list nobody reads.
///
/// This is not a skip list, and the difference is the whole design. A skipped mutant is not
/// measured and nothing is learned. An expected one is measured on every run and never
/// answered from the cache, and three things are then possible: it survives and the
/// expectation is met; it is killed, which means somebody wrote the test after all and the
/// note in their configuration is now untrue; or it is no longer in the catalogue, which
/// means the code moved and nobody updated the note.
///
/// The last two fail the run. An expectation that quietly stopped applying is worse than no
/// expectation, because somebody is relying on it.
public enum Expectations {

    /// What a set of expectations amounted to.
    public struct Verdict: Sendable, Hashable {

        /// How many were met by a mutant that survived, as written.
        public let met: Int

        /// Expectations a mutant contradicted by being caught.
        public let contradicted: [Contradiction]

        /// Expectations naming a mutant the catalogue no longer has.
        public let stale: [Configuration.Expectation]

        /// Expectations about a mutant the compiler proved could never be caught.
        ///
        /// Not a failure: the note was true and is now unnecessary, which is news rather
        /// than a mistake.
        public let superseded: [Configuration.Expectation]

        /// Whether nothing in the configuration is wrong.
        public var isSatisfied: Bool { contradicted.isEmpty && stale.isEmpty }

        /// Whether the configuration had anything to say at all.
        public var isEmpty: Bool {
            met == 0 && contradicted.isEmpty && stale.isEmpty && superseded.isEmpty
        }

        /// A configuration with no expectations in it.
        public static let unasked = Self(
            met: 0, contradicted: [], stale: [], superseded: [])

        /// Records what a set of expectations amounted to.
        public init(
            met: Int,
            contradicted: [Contradiction],
            stale: [Configuration.Expectation],
            superseded: [Configuration.Expectation]
        ) {
            self.met = met
            self.contradicted = contradicted
            self.stale = stale
            self.superseded = superseded
        }
    }

    /// One expectation a run disagreed with.
    public struct Contradiction: Sendable, Hashable {

        /// The expectation as written.
        public let expectation: Configuration.Expectation

        /// Why the run disagrees, in the words a fix needs.
        public let reason: String

        /// Records one disagreement.
        public init(expectation: Configuration.Expectation, reason: String) {
            self.expectation = expectation
            self.reason = reason
        }
    }

    /// What a run's answers say about a project's expectations.
    ///
    /// A mutant nothing was established about - it errored, it ran out of time once, it was
    /// another machine's, the compiler refused it - is not evidence either way. Calling one
    /// of those a contradiction would fail somebody's build because a machine was busy.
    ///
    /// `scope` decides one thing only: whether an expectation naming a mutant that is not
    /// in the results is stale. A run about everything looked at the whole catalogue, so an
    /// absence means the code moved and nobody updated the note. A run about four changed
    /// files never looked, so the same absence means nothing at all - and reporting it as
    /// stale would fail somebody's build for using `--changed` while their note was true
    /// the whole time. Sharding needs no such rule: another machine's mutants come back as
    /// `not-run` rows, which say nothing by the paragraph above.
    public static func check(
        _ expectations: [Configuration.Expectation],
        against outcomes: [String: Outcome],
        about scope: RunScope = .everything
    ) -> Verdict {
        var met = 0
        var contradicted: [Contradiction] = []
        var stale: [Configuration.Expectation] = []
        var superseded: [Configuration.Expectation] = []

        for expectation in expectations {
            guard let outcome = outcomes[expectation.identity] else {
                if scope == .everything { stale.append(expectation) }
                continue
            }
            switch outcome {
            case .survived:
                met += 1
            case .killed, .timedOut:
                contradicted.append(
                    Contradiction(
                        expectation: expectation,
                        reason: """
                            this was caught, so it is not the survivor the configuration \
                            says it is: "\(expectation.reason)"
                            """
                    ))
            case .equivalent:
                superseded.append(expectation)
            case .inconclusive, .errored, .notRun, .rejected:
                // Nothing was established, so nothing is said. A build that failed because
                // a machine was busy would be a build people stop trusting.
                break
            }
        }
        return Verdict(
            met: met, contradicted: contradicted, stale: stale, superseded: superseded)
    }
}
