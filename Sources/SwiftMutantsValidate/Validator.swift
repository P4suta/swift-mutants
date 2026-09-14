// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

import SwiftMutantsCore
import SwiftMutantsDiscover
import SwiftMutantsInstrument

/// Works out which mutants the compiler will accept.
///
/// The loop is: instrument everything, ask once, drop what was refused, ask again. It ends
/// because every round that finds a rejection removes at least one candidate, so it cannot
/// run more times than there are candidates - and in practice it ends after two compiles,
/// one that finds every rejection at once and one that confirms what is left.
///
/// That is the whole reason ``InstrumentedMutant/instrumentedSpan`` exists. `swiftc`
/// reports every error in a file rather than stopping at the first, and points `line:col`
/// at the operator inside the branch that broke, so one compile names every refusal.
/// Bisection - a compile per halving - is the fallback for a compile that will not say
/// where it hurts, not the mechanism.
///
/// A compile that explains only some of what it is unhappy about is still worth acting on.
/// Dropping the mutants it did place is cheaper than halving for all of them, and it often
/// removes the cause of the errors it did not place. Only a compile that fails while
/// naming nothing this tool put there falls through to halving, and a rejection found that
/// way carries no diagnostics - because there were none to carry, not because they were
/// discarded.
public struct Validator: Sendable {

    let compiler: any TypecheckDriver
    let directory: URL

    /// Prepares to validate into `directory`, which is written to and nothing else is.
    public init(compiler: any TypecheckDriver, directory: URL) {
        self.compiler = compiler
        self.directory = directory
    }

    /// What a validation is doing, for somebody watching it.
    ///
    /// Each round is a build, and a build of somebody's package is the slowest thing this
    /// tool does. A person watching twenty silent minutes cannot tell a second round from
    /// a hang, and the difference matters: one is progress and the other is a bug.
    public enum Progress: Sendable, Hashable {

        /// A round is starting, with this many mutants still in the tree.
        case compiling(round: Int, mutants: Int)

        /// A round finished and the compiler refused these.
        case refused(round: Int, count: Int)

        /// The compile would not say what it was unhappy about, so halving has begun.
        ///
        /// Carries the first error nobody could place, because that is the whole
        /// explanation for being on the expensive path and a reader has no other way to
        /// see it. Usually it means a diagnostic arrived from somewhere this tool did not
        /// put a mutant - a macro buffer, a synthesised declaration, a linker.
        case halving(mutants: Int, unplaceable: CompilerDiagnostic?)
    }

    /// Narrows each file to the mutants the compiler accepts.
    public func validate(
        _ files: [FileUnderValidation],
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws(ValidationError) -> Validation {
        var discoveries = files.map(\.discovery)
        var rejected: [Rejection] = []
        var rounds = 0
        var passes = 0
        var bisected = false

        // At most one pass per candidate, because a pass that changes nothing ends the
        // loop and a pass that changes something removes at least one candidate.
        //
        // Counted separately from `rounds`, which is compiles. A pass that halves spends
        // many compiles on one pass, and a ceiling that confused the two would give up
        // part way through a run that was making perfectly good progress.
        let ceiling = discoveries.reduce(1) { $0 + $1.candidates.count }
        while passes < ceiling {
            passes += 1
            rounds += 1
            progress(
                .compiling(
                    round: rounds, mutants: discoveries.reduce(0) { $0 + $1.candidates.count }))
            let instrumented = try Self.instrument(files, as: discoveries)
            let paths = try write(instrumented, for: files)
            let output = await compiler.typecheck(paths)
            guard output.exitCode != 0 else {
                return Validation(
                    files: zip(paths, instrumented).map {
                        ValidatedFile(path: $0, instrumented: $1)
                    },
                    rejected: rejected,
                    rounds: rounds,
                    bisected: bisected
                )
            }
            let attribution = Self.attribute(output, to: paths, and: instrumented)
            if !attribution.rejected.isEmpty {
                progress(.refused(round: rounds, count: attribution.rejected.count))
                rejected += attribution.rejected
                discoveries = Self.dropping(attribution.rejected, from: discoveries)
                continue
            }

            // The compile failed while naming nothing this tool put there. Guessing from
            // here is how a tool starts rejecting mutants at positions nobody reported, so
            // it stops guessing and pays for halving instead.
            // Halving is another way to remove candidates, not another way to finish.
            // `swift build` stops at the first module that fails, so a clean build of one
            // layer is what lets the next layer's errors appear at all - and they do. The
            // loop is the only thing that decides a tree compiles.
            let found = try await halve(
                files,
                from: Rounds(discoveries: discoveries, rejected: rejected, rounds: rounds),
                blaming: attribution.unattributed,
                progress: progress
            )
            bisected = true
            rejected += found.rejected
            discoveries = found.discoveries
            rounds += found.rounds
        }
        throw ValidationError(
            """
            validation did not settle after \(rounds) compiles. Each round should remove at \
            least one mutant, so this means the compiler refused the same tree twice.
            """
        )
    }

    /// The expensive path: corner the refusals by halving.
    ///
    /// Hands back what it found rather than deciding the run is over. `swift build` stops
    /// at the first module that fails, so removing one layer's refusals is what lets the
    /// next layer's errors appear - and the loop, not this, is what decides a tree
    /// compiles.
    private func halve(
        _ files: [FileUnderValidation],
        from state: Rounds,
        blaming unplaceable: [CompilerDiagnostic],
        progress: @Sendable (Progress) -> Void
    ) async throws(ValidationError) -> Bisection {
        // The errors nobody could place still name files. A `missing return` is reported
        // at a closing brace, nowhere near the mutant that removed the return - but it is
        // reported in the file that mutant is in. Halving that file's candidates first
        // costs a compile per halving of twenty rather than of six hundred, and widening
        // to everything is still there for when it finds nothing.
        let suspects = Self.suspects(named: unplaceable, among: files)
        progress(
            .halving(
                mutants: Self.candidates(in: state.discoveries, restrictedTo: suspects).count,
                unplaceable: unplaceable.first
            ))
        return try await bisect(
            files, discoveries: state.discoveries, suspecting: suspects)
    }

    /// Reads what the compiler said and works out which mutants it was about.
    private static func attribute(
        _ output: CompilerOutput, to paths: [String], and instrumented: [InstrumentedFile]
    ) -> Attribution {
        Attribute.diagnostics(
            CompilerDiagnostic.parse(output.text),
            to: Dictionary(uniqueKeysWithValues: zip(paths, instrumented))
        )
    }

    /// Every discovery with the refused candidates taken out of it.
    ///
    /// Acting on what the compiler explained, even when it did not explain everything.
    /// Dropping the placed refusals is strictly cheaper than halving for all of them, and
    /// it often removes the cause of the errors that could not be placed - a compile the
    /// loop then does not have to spend. Whatever is still wrong comes back on the next
    /// round with a smaller catalogue behind it.
    private static func dropping(
        _ rejections: [Rejection], from discoveries: [FileDiscovery]
    ) -> [FileDiscovery] {
        let refused = Set(rejections.map { Key($0.span, $0.rule) })
        return discoveries.map { discovery in
            discovery.keeping { !refused.contains(Key($0.span, $0.rule)) }
        }
    }

    /// Which files the compiler complained about, by position in `files`.
    ///
    /// Matched on the path with its links resolved, the same way attribution does, because
    /// the compiler and this tool spell a temporary directory differently.
    static func suspects(
        named diagnostics: [CompilerDiagnostic], among files: [FileUnderValidation]
    ) -> Set<Int> {
        let blamed = Set(diagnostics.map { Attribute.resolved($0.file) })
        return Set(
            files.indices.filter { position in
                blamed.contains { $0.hasSuffix("/" + files[position].name) }
            })
    }

    /// Every candidate, or only those in the files named.
    static func candidates(
        in discoveries: [FileDiscovery], restrictedTo suspects: Set<Int>
    ) -> [Located] {
        discoveries.enumerated()
            .filter { suspects.isEmpty || suspects.contains($0.offset) }
            .flatMap { position, discovery in
                discovery.candidates.map { Located(file: position, key: Key($0.span, $0.rule)) }
            }
    }

    /// Where the loop had got to when it gave up explaining itself.
    private struct Rounds {
        let discoveries: [FileDiscovery]
        let rejected: [Rejection]
        let rounds: Int
    }

    /// What identifies a candidate inside one file: the bytes it edits and the rule.
    struct Key: Hashable {
        let span: SourceSpan
        let rule: RuleIdentifier
        init(_ span: SourceSpan, _ rule: RuleIdentifier) {
            self.span = span
            self.rule = rule
        }
    }

    // MARK: - Rounds

    /// Instruments every file, numbering the mutants through the whole set.
    ///
    /// Through, not per file: every instrumented file reads the same
    /// `SWIFT_MUTANTS_ACTIVE`, so a file numbered from zero means one value wakes the same
    /// index in all of them. Measured on this repository before this existed: fifty-nine
    /// files, so a run asking for mutant 3 woke up to fifty-nine mutants at once and
    /// reported what it learned as a fact about one of them.
    static func instrument(
        _ files: [FileUnderValidation], as discoveries: [FileDiscovery]
    ) throws(ValidationError) -> [InstrumentedFile] {
        var instrumented: [InstrumentedFile] = []
        var next: UInt32 = 0
        for (file, discovery) in zip(files, discoveries) {
            do {
                let one = try Instrument.file(
                    file.source, discovery: discovery, startingAt: next)
                next = one.nextIndex
                instrumented.append(one)
            } catch {
                throw ValidationError("\(file.name) could not be instrumented: \(error)")
            }
        }
        return instrumented
    }

    func write(
        _ instrumented: [InstrumentedFile], for files: [FileUnderValidation]
    ) throws(ValidationError) -> [String] {
        var paths: [String] = []
        for (file, built) in zip(files, instrumented) {
            let destination = directory.appending(path: file.name)
            do {
                try Data(built.source.utf8).write(to: destination)
            } catch {
                throw ValidationError("\(destination.path) could not be written: \(error)")
            }
            paths.append(destination.path)
        }
        return paths
    }

    /// One compile over the current discoveries, kept if the compiler accepts it.
    private func confirm(
        _ files: [FileUnderValidation], discoveries: [FileDiscovery]
    ) async throws(ValidationError) -> (files: [ValidatedFile], rounds: Int) {
        let instrumented = try Self.instrument(files, as: discoveries)
        let paths = try write(instrumented, for: files)
        let output = await compiler.typecheck(paths)
        guard output.exitCode == 0 else {
            throw ValidationError(
                """
                the tree still does not compile with every refused mutant removed, which \
                means the file does not compile on its own.
                """,
                diagnostics: CompilerDiagnostic.parse(output.text)
            )
        }
        return (zip(paths, instrumented).map { ValidatedFile(path: $0, instrumented: $1) }, 1)
    }

}
