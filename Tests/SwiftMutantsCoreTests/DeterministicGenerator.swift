// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A seeded generator, so a property test that fails fails the same way twice.
///
/// The point of a generated case is to reach a shape nobody thought to write down; the
/// point of seeding it is that once it does, the failure can be reproduced from the seed
/// printed beside it rather than by running the suite until it happens again.
///
/// SplitMix64, which is four lines and has no state to get wrong. The sequence is part of
/// the test rather than of the product, so it needs to be reproducible, not unpredictable.
struct DeterministicGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return mixed ^ (mixed >> 31)
    }
}
