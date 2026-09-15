// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// How long one validation compile may take, derived from what building the package cost.
///
/// It was thirty minutes, for every package alike, and a flat number is wrong in both
/// directions at once.
///
/// A package that builds in ten seconds got half an hour before anything noticed it had
/// hung - and a halving round costs one of these, so a catalogue that falls through to
/// bisection pays it per round. That is the difference between a run that is slow and a run
/// somebody kills.
///
/// A package that takes five minutes to build got *less than six of its own builds*, which
/// is the other mistake and the worse one. A compile killed part way is a tree reported as
/// refusing mutants it would have accepted, rejected mutants leave the denominator, and the
/// score goes up. Silent, and in the flattering direction.
///
/// The measurement is already taken. A run builds the package as it was written before it
/// touches anything - to know whether the baseline is red, and to give the module driver
/// interfaces to compile against. That build is the same package, cold, with code
/// generation. A validation round is warmer, is only the modules that changed, and does no
/// code generation at all. So a validation compile taking many times what the whole package
/// cost is not slow; it is stuck.
///
/// Every unknown resolves towards more time, for the same reason as everywhere else in this
/// tool: a deadline met is a refusal nobody ever finds out about, and a deadline too loose
/// costs time only when something is genuinely stuck.
public enum CompileDeadline {

    /// The least any compile gets.
    ///
    /// A first build can be quick for reasons that say nothing about what compiling the
    /// same package with guards in it will cost - a warm cache, a package that is mostly
    /// one small module - and a deadline of a few seconds would refuse a tree for being
    /// ordinary.
    public static let floor = Duration.seconds(300)

    /// What a compile gets when nothing was measured.
    ///
    /// Nothing measured is not zero measured. A build whose duration could not be read
    /// establishes nothing about what compiling costs here, and answering as though it had
    /// been measured at zero would hand every package the floor. So it is what this did
    /// before the measurement existed, which is at least a number somebody chose.
    public static let unmeasured = Duration.seconds(1800)

    /// How many of the package's own builds one compile may take.
    ///
    /// Ten rather than two or a hundred. Two would be inside the ordinary variation between
    /// a cold build and a warm one; a hundred is not a bound on anything. Ten is past any
    /// overhead the guards themselves add - which ADR 0002 establishes is linear in the
    /// number of guards at a site, not combinatorial - while still bounding a hang at
    /// something proportional to the package rather than at a number from nowhere.
    ///
    /// Deliberately not capped. "Ten times what your own package costs to build" stays a
    /// sentence somebody can check against their machine at any size; a ceiling would make
    /// it true only below whatever size the ceiling was.
    public static let builds = 10

    /// The deadline for a package whose own build took this long.
    public static func after(_ priming: Duration?) -> Duration {
        guard let priming else { return Self.unmeasured }
        let derived = priming * Self.builds
        return derived > Self.floor ? derived : Self.floor
    }
}
