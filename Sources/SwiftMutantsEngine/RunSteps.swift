// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import SwiftMutantsBuild
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import SwiftMutantsSnapshot
import SwiftMutantsValidate

/// The steps a run is made of: copying, reading, validating, building.
///
/// Separated from the pipeline that orders them, because the order is the argument and
/// these are the errands.
extension Run {

    func snapshot(_ progress: @Sendable (RunStage) -> Void) throws(RunError) -> URL {
        progress(.snapshotting)
        let tree = workspace.appending(path: "tree")
        do {
            _ = try Snapshot.create(of: root, at: tree)
        } catch {
            throw RunError("\(root.path) could not be copied: \(error)")
        }
        Self.lendDependencies(from: root, to: tree)
        return tree
    }

    func list(environment: [String: String]) async throws(RunError) -> Listing {
        do {
            return try await Lister(
                root: root, configuration: configuration, runner: runner, executable: executable
            ).list(environment: environment)
        } catch {
            throw RunError("\(root.path) could not be read: \(error)")
        }
    }

    /// Hands the copy the dependencies the original already has.
    ///
    /// A snapshot leaves `.build` behind, which is right for build artefacts and wrong for
    /// the dependency checkouts inside it: without them SwiftPM fetches every dependency
    /// again, once per run. That is a network round trip and a set of credentials a
    /// mutation run has no business needing - and on a machine whose git rewrites GitHub
    /// URLs to SSH, it is an agent prompt in the middle of an hour-long job.
    ///
    /// Only the fetched sources are lent, never the built products: a run must compile the
    /// instrumented tree itself, and inheriting object files from the original would be
    /// inheriting an answer about a different program.
    ///
    /// Best effort. A copy that fails leaves SwiftPM to fetch as it would have anyway, so
    /// this can make a run faster and cannot make one fail.
    public static func lendDependencies(from root: URL, to tree: URL) {
        let source = root.appending(path: ".build")
        let destination = tree.appending(path: ".build")
        for name in ["repositories", "checkouts", "artifacts", "workspace-state.json"] {
            let from = source.appending(path: name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try? FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: from, to: destination.appending(path: name))
        }
    }

    /// The files to instrument, read from the copy rather than from the original.
    ///
    /// Read from the copy because that is what will be compiled, and a file that changed
    /// between the two would be a catalogue about one program and a build about another.
    func subjectsToValidate(
        _ listing: Listing, in tree: URL
    ) throws(RunError) -> [FileUnderValidation] {
        var subjects: [FileUnderValidation] = []
        for path in listing.filesWithMutants {
            let file = tree.appending(path: path.rendered)
            guard let source = try? String(contentsOf: file, encoding: .utf8) else {
                throw RunError("\(file.path) could not be read out of the copy")
            }
            subjects.append(
                FileUnderValidation(
                    name: path.rendered,
                    source: source,
                    discovery: Discover.candidates(in: source, at: path)
                )
            )
        }
        return subjects
    }

    func validate(
        _ subjects: [FileUnderValidation],
        in tree: URL,
        environment: [String: String],
        progress: @Sendable (RunStage) -> Void
    ) async throws(RunError) -> Validation {
        // SwiftPM rather than a bare `swiftc`, because a package is not a pile of files:
        // each target compiles on its own, against its own dependencies and search paths.
        // The same place the tests are built into, so the build that proves the mutants
        // compile *is* the build that produces them.
        let validator = Validator(
            compiler: SwiftBuildDriver(
                runner: runner,
                executable: executable,
                root: tree.path,
                scratch: Self.buildDirectory(in: tree).path,
                environment: environment
            ),
            directory: tree
        )
        do {
            return try await validator.validate(subjects) { progress(.validating($0)) }
        } catch {
            throw RunError("the instrumented copy could not be validated: \(error)")
        }
    }

    /// Every mutant in the catalogue has to be in the file, before anything is run.
    ///
    /// Muter assumed insertion and reported four hundred mutants as newly surviving when in
    /// fact none had been inserted at all. Assuming is the mistake; this is the check that
    /// makes it impossible rather than unlikely.
    func prove(_ files: [InstrumentedFile]) throws(RunError) {
        for file in files {
            let proof = ActivationProof.inSource(file)
            guard proof.isProved else {
                let missing = proof.absences.map(\.marker).prefix(3).joined(separator: ", ")
                throw RunError(
                    """
                    \(proof.expected - proof.found) of \(proof.expected) mutants are not in \
                    the instrumented file (\(missing)). Running would report them as \
                    surviving tests that never had a chance to catch them.
                    """
                )
            }
        }
    }

    func buildTests(
        in tree: URL, environment: [String: String]
    ) async throws(RunError) -> TestPlan {
        do {
            let plan = try await SwiftPackageManager(
                root: tree, runner: runner, executable: executable
            ).buildForTesting(
                scratch: Self.buildDirectory(in: tree).path,
                environment: environment,
                timeout: .seconds(1800)
            )
            guard !testArguments.isEmpty else { return plan }
            return TestPlan(
                executable: plan.executable,
                arguments: plan.arguments + testArguments,
                environment: plan.environment,
                directory: plan.directory,
                eventStreamVersion: plan.eventStreamVersion
            )
        } catch {
            throw RunError("the instrumented copy could not be built: \(error)")
        }
    }
}
