// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// The one place this program reads its own environment.
///
/// A command-line tool has to look at the environment it was started in - that is how it
/// finds a toolchain, an SDK, a CI runner. The question is not whether to read it but
/// where, and the answer is here, in a file named in the `no-process-info-environment`
/// rule's ignore list and asserted by `AmbientGateTests`. Everything below the command
/// line receives an environment as an argument instead, which is what makes the engine
/// testable against a scripted toolchain and what lets `Runner` record the environment a
/// child process actually received rather than the one it probably got.
///
/// Read once, not per access: `ProcessInfo.processInfo.environment` materialises a whole
/// dictionary from `environ` every time it is touched.
public enum Ambient {

    /// What this process was started with.
    public static let environment: [String: String] = ProcessInfo.processInfo.environment
}
