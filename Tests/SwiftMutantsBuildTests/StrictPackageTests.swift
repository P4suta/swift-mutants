// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsBuild
import Testing

/// Compiling a mutant for a package that treats its own warnings as errors.
@Suite("A package that is strict about warnings")
struct StrictPackageTests {

    /// A package that treats its own warnings as errors.
    ///
    /// A mutation is exactly the edit that produces a warning: `a + b` becomes `a`, and a
    /// value stops being used. Under `.treatAllWarnings(as: .error)` the compiler then calls
    /// that an error, so a mutant that is a perfectly good question about somebody's tests
    /// comes back `rejected`.
    ///
    /// And rejected mutants leave the denominator. So the score of a strict package goes
    /// *up* because it is strict - the flattering direction, arrived at silently, which is
    /// the shape of failure this repository keeps having to dig out.
    ///
    /// The mutant is compiled in a copy nobody ships. What the compile is being asked is
    /// "is this a well-formed program", and a warning is by definition not ill-formedness.
    /// Reported by a project that had just added `.treatAllWarnings(as: .error)` and
    /// expected its uncompilable set to jump.
    @Test("says warnings are warnings, whatever the package says")
    func demotesWarningsAsErrors() {
        let module = BuildManifest.Module(
            name: "Core",
            arguments: ["/usr/bin/swiftc", "-c", "-warnings-as-errors", "a.swift"],
            sources: ["a.swift"]
        )
        let asked = module.diagnosingArguments
        #expect(asked.last == "-no-warnings-as-errors", "\(asked)")
        // Last, because the compiler takes the last word on the subject and the package's
        // own flag is somewhere in the middle of its plan.
        guard let strict = asked.firstIndex(of: "-warnings-as-errors"),
            let demoted = asked.firstIndex(of: "-no-warnings-as-errors")
        else {
            Issue.record("one of the two flags is missing from \(asked)")
            return
        }
        #expect(strict < demoted)
    }

    /// The same for the lowering the equivalence check uses. It is the same compile with
    /// the answer kept, and a mutant that could not be lowered because of a warning would
    /// be reported as unproven rather than as equivalent.
    @Test("says the same when it is lowering rather than diagnosing")
    func demotesForLoweringToo() {
        let module = BuildManifest.Module(
            name: "Core",
            arguments: ["/usr/bin/swiftc", "-c", "-warnings-as-errors", "a.swift"],
            sources: ["a.swift"]
        )
        #expect(module.loweringArguments(cachingModulesIn: nil).contains("-no-warnings-as-errors"))
    }
}
