// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConfig
import SwiftMutantsDiscover

/// The file a project starts from.
///
/// The configuration is read by every command, and nothing told anybody it existed. A
/// setting that works and cannot be discovered is a setting nobody uses, which is the same
/// outcome as one that does not work and costs more to maintain.
///
/// Every setting, commented out, with what it is for beside it. Commented rather than set,
/// because a starter file that turned things on would be this tool making decisions about
/// somebody's package by being run once - and a project that copied it without reading it
/// would be measuring under settings nobody chose.
///
/// Uncommenting is the whole interaction, so a test parses it with every setting
/// uncommented as well as as-written: a starter file whose examples do not parse once
/// enabled is worse than no starter file.
enum StarterConfiguration {

    /// The tiers, written out of the table a run reads rather than beside it.
    ///
    /// A comment that lists what a setting does is a second copy of the setting, and two
    /// copies of anything drift. This one would drift the moment a rule joined a family -
    /// and it would drift *quietly*, into the file this tool hands somebody as the
    /// explanation of what their own choices mean.
    static var tierLines: String {
        RuleSelection.tiers
            .map { step in
                let adds =
                    step.adds.isEmpty
                    ? "nothing yet; the rules its tier is for are not built"
                    : step.adds.sorted().joined(separator: ", ")
                // No leading indentation: a multiline literal strips its own, and an
                // interpolation is spliced in after that has happened - so anything this
                // adds would land in the file as a comment indented past every other one.
                let name = step.tier.rawValue
                let pad = String(repeating: " ", count: max(0, Self.tierColumn - name.count))
                return "#   \(name)\(pad)\(adds)"
            }
            .joined(separator: "\n")
    }

    /// How wide the tier names are written, so what each adds lines up under the next.
    static let tierColumn = 10

    /// What `init` writes.
    static var text: String {
        """
        # How this package is measured. Every setting here is commented out, so this file
        # changes nothing until you uncomment something.
        #
        # Every command reads it: `run`, `list` and `why-skipped` alike, so what `list`
        # describes is what `run` would do.

        [mutation]

        # Which operators to use. Each tier contains the one below it.
        \(Self.tierLines)
        # A rule a tier leaves out is reported by `why-skipped`, not silently absent.
        # profile = "balanced"

        # Which files to measure. Absent means every file the package builds.
        # include = ["Sources/**"]
        # exclude = ["Sources/Generated/**"]

        # Only these operators, by name, whatever the profile says.
        # operators = ["add-to-sub", "lt-to-le"]

        # A survivor you have decided about. Checked rather than skipped: the mutant is
        # measured every time, and a run fails if it is caught after all, because that means
        # the reason no longer holds.
        # [[mutation.expect]]
        # id = "0000000000000000000000000000000000000000000000000000000000000000"
        # reason = "unsigned, so <= and < agree here"

        # A mutation you wrote yourself, because it encodes what the code is for. Anchored by
        # text rather than by line, so it survives everything above it moving.
        # [[mutation.custom]]
        # file = "Sources/Core/Order.swift"
        # find = "entries.sorted()"
        # replace = "entries"
        # reason = "is the sort load-bearing, or only tidy"

        [test]

        # How to run your tests. Spelled strictly: an unrecognised command means every
        # mutant faces every test, and a run says so.
        # command = ["swift", "test"]

        # How long one mutant may take: "500ms", "120s", "2m", "1h". Leave it out and a run
        # derives both a processor allowance and a deadline from your own suite, which is
        # what makes a verdict about your program rather than about how busy the machine was.
        # timeout = "120s"

        # How much memory one mutant may use: "512B", "2KiB", "3MiB", "4GiB".
        # memory = "4GiB"

        # How many times to measure the baseline before trusting it.
        # baseline_runs = 3

        [execution]

        # How many mutants at once. Defaults to this machine's cores; turn it down if your
        # suite cannot run beside itself.
        # jobs = 4

        [cache]

        # Whether to reuse answers an earlier run established: `auto`, `on` or `off`.
        # `swift-mutants cache status` says what is kept.
        # mode = "auto"

        [policy]

        # Fail a run that found survivors. Off by default: finding survivors is answering
        # the question, and a tool that exits non-zero for answering is one people stop
        # running.
        # strict = true

        # Fail a run that scored below this.
        # minimum_score = 80

        [report]

        # Where to write the documents, inside your package.
        # directory = "reports/mutation"

        # Which to write: json, html, sarif.
        # formats = ["html"]

        # The scores the report colours as good and as poor.
        # high = 80
        # low = 60
        """
    }
}
