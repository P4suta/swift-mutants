// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsBuild
import SwiftMutantsExecute
import SwiftMutantsReport
import SwiftMutantsRunner

/// One mutant's whole story, for somebody deciding what to do about it.
///
/// A run's summary says a hundred and eighty things survived. That is a number, not a task.
/// The work is one mutant at a time - what was changed, where, which tests ran and did not
/// notice - and the two kinds of survivor are different problems with different fixes: one
/// wants an assertion, the other wants a test or a deletion. Saying which is most of the
/// value here.
enum Explanation {

    /// How many tests to name before the list stops being something a person reads.
    ///
    /// A mutant reached by four hundred tests is a mutant whose problem is not the list.
    static let namedTests = 20

    /// One mutant, in the words a fix needs.
    ///
    /// `invocation` is how the run started a mutant, which turns into the command somebody
    /// pastes to watch this one happen. Absent for a caller that has no report to hand -
    /// and then the story is told without the last chapter rather than with an invented one.
    static func of(
        _ mutant: RunReport.Mutant,
        reachedBy tests: [String],
        with invocation: RunReport.Invocation? = nil
    ) -> [String] {
        var lines = [
            "\(Self.place(of: mutant))  \(mutant.rule)",
            "  \(mutant.original)  ->  \(mutant.replacement)",
            "  \(mutant.id)",
            "",
        ]
        lines += Self.verdict(of: mutant, reachedBy: tests)
        if let invocation {
            lines += Self.reproduction(of: mutant, reachedBy: tests, with: invocation)
        }
        return lines
    }

    /// The command that ran one mutant, for somebody who wants to watch it happen.
    ///
    /// A summary says a hundred and eighty things survived. That is a number, not a task,
    /// and the fastest way into one of them is to run it under a debugger. Working out how
    /// by hand means knowing which bundle, which environment variable, which spelling of a
    /// filter, and which of three flags the runner adds - an afternoon nobody should spend.
    ///
    /// The line comes from the same function the runner builds its own commands with, so
    /// what somebody pastes is what ran. A command assembled here instead would be a
    /// plausible-looking line that works until the day the runner adds a flag, and then it
    /// silently runs a different program: the mutant behaves differently under the debugger
    /// than it did in the report, and nobody can tell why.
    static func reproduction(
        of mutant: RunReport.Mutant,
        reachedBy tests: [String],
        with invocation: RunReport.Invocation
    ) -> [String] {
        // Nothing to reproduce for a mutant something caught: whoever reads this already
        // has the test that caught it, which is a better place to start than a debugger.
        guard invocation.isKnown, mutant.outcome != "killed" else { return [] }

        // The bundles this mutant's tests live in, and only those. A package builds one
        // per test target, so naming any other would hand somebody a command that runs a
        // different target from the one that measured their mutant - it would find
        // nothing, and read as this tool having lied about the mutant surviving.
        let bundles = invocation.covering(tests)
        let commands = bundles.map { bundle in
            let spec = Launch(
                plan: TestPlan(
                    executable: bundle.executable,
                    arguments: bundle.arguments,
                    environment: invocation.environment,
                    directory: invocation.directory,
                    eventStreamVersion: invocation.eventStreamVersion,
                    module: bundle.module
                ),
                worker: 0,
                timeout: nil
            ).specification(
                writingEventsTo: "/dev/null",
                // A mutant nothing reached was offered no test, and filtering to none of
                // them would run nothing at all - so it runs the suite, which is what the
                // run did.
                waking: [UInt32(clamping: mutant.index)],
                onlyTests: Self.share(of: tests, in: bundle.module)
            )
            return "    \(ProcessSpec.rendered(spec, showing: Set(invocation.environment.keys)))"
        }
        return [
            "",
            bundles.count == 1
                ? "to watch it happen:" : "to watch it happen, in each bundle that ran it:",
            "  cd \(invocation.directory) && \\",
        ] + commands + [
            "  "
                + (invocation.kept
                    ? "that copy is still there, because this run was asked to keep it."
                    : "that copy has been deleted. Run again with --keep-temp to keep it,")
        ]
            + (invocation.kept
                ? []
                : [
                    // The cheaper offer, second because it is the less exact one: the
                    // command above is what actually ran, and this is the same experiment
                    // done by hand. But a mutant is one edit to one span and this report
                    // says which, so applying it to your own tree costs a minute where a
                    // re-run costs a run. Reported by somebody who reproduced two mutants
                    // by hand rather than pay 56 minutes to look at one `-` become a `+`.
                    "  or make the one edit above in your own tree and run those tests -"
                        + " it is the same experiment."
                ])
    }

    /// The tests of `tests` that live in this bundle, or nothing to mean all of them.
    ///
    /// A filter naming a test that is not in the bundle matches nothing, and a run of no
    /// tests reads exactly like a mutant nothing noticed - which is the thing somebody is
    /// pasting this command to investigate.
    static func share(of tests: [String], in module: String) -> [String]? {
        guard !tests.isEmpty else { return nil }
        guard !module.isEmpty else { return tests }
        let mine = tests.filter { $0.hasPrefix("\(module).") }
        return mine.isEmpty ? tests : mine
    }

    /// Where it is, in the words an editor takes - or in bytes, when the line is unknown.
    ///
    /// A position that was never worked out is said plainly rather than printed as `:0:0`,
    /// which an editor would take somewhere wrong and a reader would believe.
    static func place(of mutant: RunReport.Mutant) -> String {
        guard let line = mutant.line.value, let column = mutant.column.value else {
            return "\(mutant.path) (bytes \(mutant.span.start)..<\(mutant.span.end))"
        }
        return "\(mutant.path):\(line):\(column)"
    }

    /// What became of it, and what to do about it.
    private static func verdict(
        of mutant: RunReport.Mutant, reachedBy tests: [String]
    ) -> [String] {
        switch mutant.outcome {
        case "killed":
            return ["killed by:"] + Self.listed(mutant.killedBy)
        case "survived" where mutant.testsStarted == 0:
            return [
                "no test reaches this, so nothing could have caught it.",
                "Either it wants a test, or the code wants deleting.",
            ]
        case "survived":
            return [
                "\(mutant.testsStarted) tests ran with this change in and all of them passed.",
                "One of them is where the missing assertion belongs:",
            ] + Self.listed(tests)
        case "timed-out":
            return [
                "this ran out of time twice, the second time with nothing else running.",
                "That counts as detected, and is shown apart from a kill because a deadline",
                "is a weaker claim than an assertion: something noticed, but not what.",
            ]
        case "rejected":
            return ["the compiler would not accept this change, so nothing could run it."]
                + Self.advice(forRefusing: mutant)
        default:
            return ["\(mutant.outcome)."]
        }
    }

    /// What to do about a refusal, when there is something to do.
    ///
    /// Almost never. A refused mutant is a fact about the program: the compiler would not
    /// accept that edit there, and nobody has anything to fix. The exception is a mutant a
    /// project wrote itself, where the refusal is about a row in their configuration
    /// rather than about their code - and where the usual cause has one answer.
    ///
    /// A guard is a ternary around the text the row matched, so that text has to be an
    /// expression. `n += 1` is one and works; `let dropped = Array(entries[limit...])` is a
    /// declaration and does not.
    ///
    /// And there is no form of guard that would. Wrapping the declaration in `if awake { }
    /// else { }` binds `dropped` inside a scope that ends at the brace, so everything after
    /// it stops compiling - the shape is not a limitation of this tool's chosen form, it is
    /// a property of what a declaration is. Anchoring on the initialiser instead costs
    /// nothing and works today.
    private static func advice(forRefusing mutant: RunReport.Mutant) -> [String] {
        guard mutant.rule.hasPrefix("custom") else { return [] }
        return [
            "",
            "This is a mutant your project wrote, so the refusal is about the row rather",
            "than about your code. A guard is a ternary around the text the row matched, so",
            "that text has to be an expression: `n += 1` is one, `let x = f()` is not.",
            "Anchor on the initialiser rather than the declaration - `f()` rather than",
            "`let x = f()` - and write the replacement as an expression of the same type.",
        ]
    }

    /// A list of tests, cut where it stops being readable.
    private static func listed(_ tests: [String]) -> [String] {
        let shown = tests.prefix(Self.namedTests).map { "  \($0)" }
        guard tests.count > Self.namedTests else { return shown }
        return shown + ["  ... and \(tests.count - Self.namedTests) more"]
    }

    /// The one mutant a person meant, if exactly one answers to what they typed.
    ///
    /// Nothing for a prefix that names two: picking the first would explain a mutant nobody
    /// asked about, and from the outside the two are indistinguishable.
    static func find(_ typed: String, among mutants: [RunReport.Mutant]) -> RunReport.Mutant? {
        let wanted = typed.lowercased()
        let matching = mutants.filter { $0.id.lowercased().hasPrefix(wanted) }
        return matching.count == 1 ? matching.first : nil
    }
}
