// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// The pure core of swift-mutants.
///
/// Nothing in this module touches the filesystem, starts a process, or reads a clock.
/// That restriction is what makes the golden identity vectors and the property tests
/// mean something, and `PurityGateTests` enforces it.
public enum SwiftMutantsCore {
    /// The version of the mutant-identity scheme this build computes.
    ///
    /// It participates in nothing yet. When the identity inputs change, this changes
    /// with them, so a cache written by an older build becomes unreachable rather than
    /// wrong.
    public static let identitySchemeVersion = 1
}
