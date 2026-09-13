// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// What became of one mutant.
///
/// The spellings are hyphenated because that is what the report schema carries, while the
/// *summary keys* beside them are snake_case (`timed_out`, `not_run`). The sibling
/// projects note that the difference is deliberate and must not be unified by anybody
/// tidying up: the values are a vocabulary that other tools read, and the keys are a
/// document's field names.
///
/// `uncovered` is deliberately absent. A mutant no test reaches has **survived** — that is
/// the honest reading, and it is the same answer the run would reach by executing every
/// test against it and watching them all pass. Coverage records it as a property of the
/// survival rather than as a ninth outcome, so that the columns of a summary still add up
/// to the number of mutants.
public enum Outcome: String, Sendable, Hashable, CaseIterable, Codable {

    /// At least one test failed with the mutant active.
    case killed

    /// The whole suite passed with the mutant active.
    case survived

    /// A timeout, confirmed by a serial retry with nothing else running.
    ///
    /// Counted as a detection: the loop the mutant created would have failed the build.
    /// A *single* timeout is not this - N test binaries on a loaded machine produce
    /// timeouts that say nothing about the mutant - and becomes ``inconclusive`` instead.
    case timedOut = "timed-out"

    /// Undecidable, and counted in neither direction.
    ///
    /// The case this exists for is a mutant that timed out once and then completed on its
    /// serial retry: the first timeout was about the machine, and the retry was about the
    /// mutant, and the two do not combine into a verdict.
    case inconclusive

    /// The harness itself failed for this mutant.
    case errored

    /// Nobody measured it, and the report says why.
    ///
    /// Out of the selection, in another shard, or the run was interrupted. Carrying the
    /// reason is what keeps a narrowed run's report a complete statement about the
    /// catalogue rather than a fragment of one.
    case notRun = "not-run"

    /// The compiler refused it, and the report carries the compiler's own words.
    case rejected

    /// The compiler proved it equivalent to the original.
    ///
    /// Trivial Compiler Equivalence: the optimised SIL of the mutated declaration is
    /// identical to the original's, so no test could distinguish them and none should be
    /// asked to.
    case equivalent

    /// Whether this outcome means the tests noticed.
    public var isDetection: Bool {
        switch self {
        case .killed, .timedOut: true
        case .survived, .inconclusive, .errored, .notRun, .rejected, .equivalent: false
        }
    }

    /// Whether this outcome belongs in the score's denominator.
    ///
    /// Excluded are every category that is a signal about the *run* rather than about the
    /// tests: an undecidable result, a harness failure, a mutant nobody executed, one the
    /// compiler refused, and one the compiler proved could not be detected by anybody.
    public var isScoreable: Bool {
        switch self {
        case .killed, .survived, .timedOut: true
        case .inconclusive, .errored, .notRun, .rejected, .equivalent: false
        }
    }
}
