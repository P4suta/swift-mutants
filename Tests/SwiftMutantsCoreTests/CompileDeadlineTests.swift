// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import SwiftMutantsCore

/// How long one validation compile may take.
///
/// It was thirty minutes, for every package alike, and a flat number is wrong in both
/// directions at once. A package that builds in ten seconds gets half an hour before
/// anything notices it has hung - and a halving step that costs thirty minutes is
/// catastrophic where a trial that costs thirty minutes is merely slow, because halving
/// spends one of these per round. A package that takes five minutes to build gets *less*
/// than six of its own builds before it is called hung, which is the other mistake and the
/// worse one: a compile killed part way is a tree reported as refusing mutants it would
/// have accepted, and rejected mutants leave the denominator.
///
/// The measurement to derive it from is already taken. A run builds the package as it was
/// written before it touches anything, both to know whether the baseline is red and to give
/// the module driver interfaces to compile against. That build is the same package, cold,
/// with code generation; a validation round is warmer, fewer modules, and type-checking
/// only. So a validation compile that takes many times what building the whole package cost
/// is not slow, it is stuck.
@Suite("How long a validation compile may take")
struct CompileDeadlineTests {

    /// The direction every unknown resolves in. A deadline met is a tree this tool reports
    /// as refusing mutants that would have compiled, and nobody ever finds out; a deadline
    /// too loose costs time only when something is genuinely stuck.
    @Test("gives a package many times its own build")
    func manyTimesTheBuild() {
        let priming = Duration.seconds(30)
        let deadline = CompileDeadline.after(priming)
        #expect(deadline > priming * 5)
    }

    /// The case the flat number was too tight for. Six of its own builds is not enough
    /// room for a package this size, and thirty minutes is six of them.
    @Test("gives a slow package more than the flat half hour it used to get")
    func slowPackagesGetMore() {
        #expect(CompileDeadline.after(.seconds(300)) > .seconds(1800))
    }

    /// And the case it was too loose for. Half an hour to notice that a ten-second package
    /// has hung is half an hour per halving round.
    @Test("gives a quick package far less than the flat half hour it used to get")
    func quickPackagesGetLess() {
        #expect(CompileDeadline.after(.seconds(10)) < .seconds(1800))
    }

    /// A floor, because the first build of a package can be quick for reasons that say
    /// nothing about what compiling it with guards in it will cost - a warm cache, a
    /// package that is mostly one small module - and a deadline of a few seconds would
    /// refuse a tree for being ordinary.
    @Test("never gives less than the floor, however quick the build was")
    func theFloor() {
        #expect(CompileDeadline.after(.milliseconds(1)) == CompileDeadline.floor)
        #expect(CompileDeadline.after(.zero) == CompileDeadline.floor)
    }

    /// Nothing measured is not zero measured. A build whose duration could not be read
    /// establishes nothing about what a compile costs, and answering as though it had been
    /// measured at zero would give every package the floor.
    @Test("falls back to what it used to do when nothing was measured")
    func nothingMeasured() {
        #expect(CompileDeadline.after(nil) == CompileDeadline.unmeasured)
        #expect(CompileDeadline.unmeasured == .seconds(1800))
    }

    /// Monotonic, because the whole claim is that a bigger package needs longer. A
    /// derivation that was not would be a number with a shape rather than a meaning.
    @Test("gives a slower build a longer deadline, always")
    func monotonic() {
        var last = CompileDeadline.floor
        for seconds in [1, 10, 60, 300, 1800] {
            let next = CompileDeadline.after(.seconds(seconds))
            #expect(next >= last, "\(seconds)s built gave \(next) after \(last)")
            last = next
        }
    }
}
