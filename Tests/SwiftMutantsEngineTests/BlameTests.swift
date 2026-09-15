// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsRunner
import Testing

@testable import SwiftMutantsEngine

/// Whose failure it is when the tests fail with nothing awake.
///
/// The symptom has two causes and they look identical from inside the copy: the tests were
/// already failing, or instrumentation broke them. One is somebody else's bug and the other
/// is this tool's, and the sentence that names the wrong one sends a reader to read a diff
/// with nothing wrong in it.
///
/// This was one sentence - "the instrumented tree does not behave like the one you wrote" -
/// said in both cases, by a tool that had never once run the tree the user wrote.
///
/// Here rather than in the integration tier because the decision is the part that can be
/// wrong in a way nobody notices. Running the untouched copy needs a real toolchain and is
/// covered there; choosing between three sentences given two verdicts needs nothing, and a
/// test that needs nothing is a test that runs on every change.
@Suite("Blaming a red baseline")
struct BlameTests {

    static func verdict(_ outcome: Outcome, killedBy: [String] = []) -> Verdict {
        Verdict(
            outcome: outcome,
            killedBy: killedBy,
            firstFailure: killedBy.first,
            startedTests: killedBy,
            durationMilliseconds: 1,
            termination: .exited(outcome == .survived ? 0 : 1)
        )
    }

    /// The package was already red. Not this tool's doing, and saying otherwise sends
    /// somebody to audit an instrumented diff that is fine.
    @Test("says the tests were already failing when the untouched copy fails too")
    func alreadyRed() {
        let said = Run.blame(
            red: Self.verdict(.killed, killedBy: ["SubjectTests/wrong()"]),
            asWritten: Self.verdict(.killed, killedBy: ["SubjectTests/wrong()"])
        )
        #expect(said.contains("your tests do not pass as you wrote them"), "\(said)")
        #expect(!said.contains("does not behave like the one you wrote"), "\(said)")
        // And which test, because "the baseline failed" is a sentence nobody can act on.
        #expect(said.contains("SubjectTests/wrong()"), "\(said)")
    }

    /// The package was green and the instrumented copy is not. This tool's doing, and the
    /// only case where the old sentence was true.
    @Test("says instrumentation broke them when the untouched copy passes")
    func instrumentationBrokeThem() {
        let said = Run.blame(
            red: Self.verdict(.killed, killedBy: ["SubjectTests/sourceText()"]),
            asWritten: Self.verdict(.survived)
        )
        #expect(said.contains("does not behave like the one you wrote"), "\(said)")
        #expect(!said.contains("your tests do not pass as you wrote them"), "\(said)")
        #expect(said.contains("SubjectTests/sourceText()"), "\(said)")
    }

    /// The untouched copy could not be built or run. Neither accusation: "I could not
    /// tell" is an honest third thing, and a tool that picked a side here would be making
    /// a guess that reads exactly like a finding.
    @Test("accuses nobody when the untouched copy could not be measured")
    func couldNotTell() {
        let said = Run.blame(
            red: Self.verdict(.killed, killedBy: ["SubjectTests/wrong()"]),
            asWritten: nil
        )
        #expect(said.contains("could not work out"), "\(said)")
        #expect(!said.contains("does not behave like the one you wrote"), "\(said)")
        #expect(!said.contains("your tests do not pass as you wrote them"), "\(said)")
    }

    /// Whichever answer it is, it says what the run did and why it stopped. A reader who
    /// gets only the verdict has been told the run failed and nothing else.
    @Test(
        "always says what came back and that the run stopped",
        arguments: [Self.verdict(.survived), Self.verdict(.killed), nil]
    )
    func alwaysExplainsItself(pristine: Verdict?) {
        let said = Run.blame(red: Self.verdict(.timedOut), asWritten: pristine)
        #expect(said.contains("with no mutant awake the tests came back timed-out"), "\(said)")
        #expect(said.contains("the run stops here"), "\(said)")
    }
}
