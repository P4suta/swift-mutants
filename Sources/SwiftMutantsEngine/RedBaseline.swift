// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsConfig
import SwiftMutantsCore
import SwiftMutantsExecute
import SwiftMutantsRunner
import SwiftMutantsSnapshot

/// Whose failure it is when the tests fail with nothing awake.
///
/// Apart from the rest of the pipeline because it is the only part of a run that exists to
/// answer a question about blame rather than one about a program, and because none of it
/// runs unless the run is already over.
extension Run {

    func provedBaseline(
        _ scheduler: Scheduler,
        environment: [String: String],
        within deadline: Duration,
        progress: @Sendable (RunStage) -> Void
    ) async throws(RunError) -> Verdict {
        let baseline = await scheduler.baseline()
        guard baseline.outcome == .survived else {
            throw await attributing(
                baseline, environment: environment, within: deadline, progress: progress)
        }
        return baseline
    }

    /// Whose failure a red baseline is.
    ///
    /// The symptom has two causes and they look identical from inside the copy: the tests
    /// were already failing, or instrumentation broke them. One is somebody else's bug and
    /// the other is this tool's, and the sentence that names the wrong one sends a reader
    /// to read a diff with nothing wrong in it. This said "the instrumented tree does not
    /// behave like the one you wrote" in both cases, having never once run the tree the
    /// user wrote.
    ///
    /// So it runs it. A second copy of the untouched workspace, built and run as written,
    /// on the failure path only: the happy path pays nothing, and the path that is about
    /// to stop the run entirely can afford one build to say something true. When even that
    /// cannot be established the answer is neither accusation, because "I could not tell"
    /// is an honest third thing and picking a side would be a guess dressed as a finding.
    func attributing(
        _ baseline: Verdict,
        environment: [String: String],
        within deadline: Duration,
        progress: @Sendable (RunStage) -> Void
    ) async -> RunError {
        progress(.attributing)
        return RunError(
            Self.blame(
                red: baseline,
                asWritten: await asWritten(environment: environment, within: deadline)))
    }

    /// Which of the two failures this is, from the two verdicts and nothing else.
    ///
    /// Separate from the work of getting the second verdict, because the decision is the
    /// part that can be wrong in a way nobody notices and the I/O is the part that cannot
    /// be run without a toolchain. Three answers from two inputs, and each one sends a
    /// reader somewhere different - so each one is worth a test that costs nothing.
    ///
    /// `asWritten` is `nil` when the untouched copy could not be built and run at all.
    /// That is an honest third thing rather than a missing second: it establishes nothing
    /// about whose failure this is, and picking a side would be a guess dressed as a
    /// finding.
    static func blame(red baseline: Verdict, asWritten pristine: Verdict?) -> String {
        let stopped = """
            with no mutant awake the tests came back \(baseline.outcome.rawValue). Every \
            later answer would be about a program nobody has, so the run stops here.
            """
        guard let pristine else {
            return """
                the tests do not pass with nothing awake, and this could not work out \
                whether that is instrumentation's doing: \(stopped)

                Your package as you wrote it could not be built and run a second time to \
                compare against, so this is not saying whose failure it is.
                \(Self.blame(baseline))
                """
        }
        guard pristine.outcome == .survived else {
            return """
                your tests do not pass as you wrote them, before anything was done to your \
                code: \(stopped)

                This is not instrumentation's doing - an untouched copy of your package was \
                built and run to check, and it failed the same way. There is nothing to \
                measure until the suite is green.
                \(Self.blame(pristine))
                """
        }
        return """
            the instrumented tree does not behave like the one you wrote: \(stopped)

            An untouched copy of your package was built and run to check, and it passed - \
            so this is this tool's doing rather than yours.
            \(Self.blame(baseline))
            """
    }

    /// Builds and runs an untouched copy of the workspace, or nothing when it cannot.
    ///
    /// `nil` rather than a verdict, and the difference decides what gets said. A copy that
    /// would not build establishes nothing about whose failure the red baseline is, and an
    /// outcome invented for it would read exactly like a measurement.
    func asWritten(environment: [String: String], within deadline: Duration) async -> Verdict? {
        let tree = workspace.appending(path: "as-written")
        guard (try? Snapshot.create(of: root, at: tree)) != nil else { return nil }
        let named = CanonicalPath.of(tree)
        Self.lendDependencies(from: root, to: named)
        guard
            let bundles = try? await buildTests(
                in: named, environment: environment, within: deadline),
            let pipes = try? pipesDirectory()
        else {
            return nil
        }
        // One worker: this is not calibrating anything, it is asking one question once.
        return await Scheduler(
            bundles: bundles,
            runner: runner,
            scratch: pipes,
            timeout: configuration.test.timeout ?? Self.calibrationBudget,
            jobs: 1
        ).baseline()
    }
}
