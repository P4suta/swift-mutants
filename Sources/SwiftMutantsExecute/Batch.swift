// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsBuild
public import SwiftMutantsInstrument

/// Several mutants run in one process, chosen so that no test can see more than one.
///
/// The remaining waste in a run is the process itself. Loading a test bundle costs what it
/// costs whether one test runs or forty, so a package with good locality - a handful of
/// tests per mutant, which is the common case - spends most of a run starting processes
/// rather than running tests. Two thousand mutants at five tests each is ten thousand test
/// executions and two thousand launches; if a launch costs what twenty tests cost, the
/// launches are five times the bill.
///
/// A batch divides that by its size. It is sound because of the one rule: no test reaches
/// two of its mutants. A failing test therefore names exactly one of them, and a batch of
/// eight is eight answers from one process rather than one.
///
/// The rule is checked, not assumed. Getting it wrong is how a tool reports what it learned
/// from breaking a program in several places as a fact about one of them - which this
/// repository did, for a different reason, and which produced a confident hundred per cent.
public struct Batch: Sendable {

    /// The mutants awake together.
    public let mutants: [InstrumentedMutant]

    /// Every test that reaches any of them, in the order they should be offered.
    public let tests: [String]

    /// Which mutant each test belongs to.
    private let owner: [String: UInt32]

    /// Groups mutants so that no two in a group share a test.
    ///
    /// Greedy and in catalogue order, which makes the grouping a function of the catalogue
    /// rather than of the machine: the same package produces the same batches, so two runs
    /// can be compared. A mutant whose covering set is unknown gets a batch of its own,
    /// because "unknown" means "possibly every test".
    ///
    /// `limit` bounds a batch rather than aiming at it: one that grows without a bound
    /// turns a single crash into a re-run of everything, and the saving is already most of
    /// the way there by eight.
    public static func group(
        _ mutants: [InstrumentedMutant],
        using coverage: Coverage,
        limit: Int = 8
    ) -> [Self] {
        // Partitioned by the bundles a mutant's tests live in, before anything is grouped.
        //
        // A batch used to cost one process. It now costs one per bundle it spans, because
        // a package builds one test bundle per test target - so a batch holding a mutant
        // from each of two targets costs two processes and saves nothing. Grouping within
        // a span first means a batch costs exactly what its first member would have cost
        // alone, and every other member is free.
        //
        // Ordered by where each span was first seen, so the batches of a package are a
        // function of its catalogue rather than of a dictionary's iteration order.
        var spans: [[String]] = []
        var bySpan: [[String]: [(mutant: InstrumentedMutant, tests: Set<String>)]] = [:]
        for mutant in mutants {
            guard let covering = coverage.tests(reaching: mutant.index), !covering.isEmpty else {
                continue
            }
            let wanted = Set(covering)
            let span = Self.bundles(of: wanted).sorted()
            if bySpan[span] == nil { spans.append(span) }
            bySpan[span, default: []].append((mutant, wanted))
        }

        var batches: [Self] = []
        for span in spans {
            var open: [Group] = []
            for entry in bySpan[span] ?? [] {
                let joined = open.firstIndex { group in
                    group.mutants.count < limit && group.tests.isDisjoint(with: entry.tests)
                }
                if let joined {
                    open[joined].mutants.append(entry.mutant)
                    open[joined].tests.formUnion(entry.tests)
                } else {
                    open.append(Group(mutants: [entry.mutant], tests: entry.tests))
                }
            }
            batches += open.map { Self($0.mutants, using: coverage) }
        }
        return batches
    }

    /// A batch while it is still being filled.
    ///
    /// No bundles here: every member of a group shares a span by construction, because the
    /// groups are built inside one.
    private struct Group {
        var mutants: [InstrumentedMutant]
        var tests: Set<String>
    }

    /// The bundles a set of tests lives in.
    ///
    /// A test names its own: swift-testing identifies it as `Module.Suite/name()`, and a
    /// test target's module is the bundle it is built into. A name with no module in front
    /// of it belongs to no bundle this can place, and is left out rather than guessed at -
    /// the effect is a group that looks narrower than it is, and the worst that costs is a
    /// batch that spans one more bundle than it meant to.
    private static func bundles(of tests: Set<String>) -> Set<String> {
        Set(tests.compactMap { TestBundles.module(of: $0) })
    }

    /// One batch, with its tests ordered and attributed.
    init(_ mutants: [InstrumentedMutant], using coverage: Coverage) {
        self.mutants = mutants
        var owner: [String: UInt32] = [:]
        var tests: [String] = []
        for mutant in mutants {
            for test in coverage.tests(reaching: mutant.index) ?? [] where owner[test] == nil {
                owner[test] = mutant.index
                tests.append(test)
            }
        }
        self.owner = owner
        self.tests = tests
    }

    /// Which mutant each test in this batch is about.
    ///
    /// What lets a process stop as soon as every mutant in it has been decided, rather than
    /// at the last test of the last one. A batch does not need every test; it needs every
    /// mutant, and running past that spends on tests exactly what the batch saved on
    /// launches.
    public var owners: [String: UInt32] { owner }

    /// Which mutant a failing test was about.
    ///
    /// Exactly one, by construction: a test is in a batch because it reaches one of its
    /// mutants, and no test reaches two. A name nobody claims is not guessed at - it means
    /// the batch was built wrong, and the caller runs its mutants one at a time instead of
    /// crediting a kill to whoever happens to be nearby.
    public func mutant(killedBy test: String) -> UInt32? { owner[test] }
}
