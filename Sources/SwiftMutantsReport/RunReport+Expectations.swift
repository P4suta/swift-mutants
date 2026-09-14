// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

extension RunReport {

    /// What a project wrote down about its own survivors, and what came of it.
    ///
    /// Three lists rather than one, because they are three different pieces of news and
    /// only two of them fail a run: an expectation can be met, contradicted by a mutant
    /// something caught, left behind by code that moved, or made unnecessary by a mutant
    /// the compiler proved equivalent.
    public struct Expectations: Codable, Sendable, Hashable {

        /// How many survived, as written down.
        public let met: Int

        /// The ones a mutant contradicted by being caught.
        public let contradicted: [ExpectationRow]

        /// The ones naming a mutant the catalogue no longer has.
        public let stale: [ExpectationRow]

        /// The ones about a mutant proved equivalent, which can now be deleted.
        public let superseded: [ExpectationRow]

        /// Whether nothing in the configuration is wrong.
        ///
        /// Stated rather than left to be derived, because it is the one bit a build acts
        /// on and two readers deriving it from three lists would eventually disagree.
        public let isSatisfied: Bool

        /// Records what a set of expectations amounted to.
        public init(
            met: Int,
            contradicted: [ExpectationRow],
            stale: [ExpectationRow],
            superseded: [ExpectationRow],
            isSatisfied: Bool
        ) {
            self.met = met
            self.contradicted = contradicted
            self.stale = stale
            self.superseded = superseded
            self.isSatisfied = isSatisfied
        }
    }

    /// One expectation, as written and as answered.
    public struct ExpectationRow: Codable, Sendable, Hashable {

        /// The mutant it names, in full.
        public let identity: String

        /// Why the project expects it to survive, in the project's own words.
        public let reason: String

        /// Why this run disagrees, when it does.
        public let disagreement: Reported<String>

        /// Records one expectation.
        public init(identity: String, reason: String, disagreement: String?) {
            self.identity = identity
            self.reason = reason
            self.disagreement = .init(disagreement)
        }
    }
}
