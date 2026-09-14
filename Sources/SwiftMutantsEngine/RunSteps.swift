// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import SwiftMutantsBuild
import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument
import SwiftMutantsRunner
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

    /// Builds the package as the user wrote it, before anything is done to it.
    ///
    /// Two things come out of one build. The first is the plainest answer a run can give:
    /// if this fails, the package does not build, and every later complaint would have been
    /// about something this tool did. Saying so here costs nothing, because the build is
    /// needed anyway.
    ///
    /// The second is what makes validation one pass instead of one per module layer. Every
    /// module's compiled interface now exists, built from the sources the user wrote, so
    /// each module can be asked on its own whether it still type-checks with mutants in it -
    /// and a module whose dependency is broken still answers, because nothing is reading
    /// the dependency's source. `swift build` cannot do that: it stops where the first
    /// module fails, so a package twenty layers deep needs twenty builds to surface twenty
    /// rejections. This package needed nineteen.
    ///
    /// Returns the plan SwiftPM made, or nothing if it could not be read - in which case
    /// validation builds the whole package each round, which is slower and always works.
    func prime(
        _ tree: URL,
        environment: [String: String],
        progress: @Sendable (RunStage) -> Void
    ) async throws(RunError) -> BuildManifest? {
        progress(.priming)
        let scratch = Self.buildDirectory(in: tree)
        let output = await Self.buildDriver(
            tree,
            scratch: scratch,
            environment: environment,
            runner: runner,
            executable: executable
        ).typecheck([])
        guard output.exitCode == 0 else {
            throw RunError(
                """
                the package does not build as it is, before any mutant was put in it. \
                Nothing below this would be about your tests. The compiler said:
                \(output.text.split(separator: "\n").suffix(20).joined(separator: "\n"))
                """
            )
        }
        guard
            let text = try? String(
                contentsOf: scratch.appending(path: "debug.yaml"), encoding: .utf8),
            let manifest = BuildManifest(parsing: text)
        else {
            return nil
        }
        return manifest
    }

    /// The driver that builds the whole package, which is always correct and never quick.
    static func buildDriver(
        _ tree: URL,
        scratch: URL,
        environment: [String: String],
        runner: Runner,
        executable: String
    ) -> SwiftBuildDriver {
        SwiftBuildDriver(
            runner: runner,
            executable: executable,
            root: tree.path,
            scratch: scratch.path,
            environment: environment
        )
    }

    func validate(
        _ subjects: [FileUnderValidation],
        in tree: URL,
        using manifest: BuildManifest?,
        environment: [String: String],
        progress: @Sendable (RunStage) -> Void
    ) async throws(RunError) -> Validation {
        // SwiftPM rather than a bare `swiftc`, because a package is not a pile of files:
        // each target compiles on its own, against its own dependencies and search paths.
        // With SwiftPM's own plan in hand each module can be asked separately, against the
        // interfaces the pristine build produced; without it, the whole package is built
        // each round, which is the same answer arrived at the slow way.
        let building = Self.buildDriver(
            tree,
            scratch: Self.buildDirectory(in: tree),
            environment: environment,
            runner: runner,
            executable: executable
        )
        let validator = Validator(
            compiler: manifest.map {
                ModuleTypecheckDriver(
                    runner: runner,
                    manifest: $0,
                    root: tree.path,
                    environment: environment,
                    fallback: building
                )
            } ?? building,
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
