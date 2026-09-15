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
        grouping(mutants, using: coverage, limit: limit).batches
    }

    /// How many candidate groups a scan may look through before opening a new one.
    ///
    /// The specification of what grouping is allowed to cost. Without a bound, an entry is
    /// compared against every group opened so far, which is quadratic in the catalogue -
    /// and the input that makes it bite is not exotic. A package with one broad test that
    /// touches most of the code gives every mutant a coverage set containing that test, so
    /// every pair conflicts, no group is ever joined, and the list of open groups grows to
    /// the size of the catalogue. That package - thin tests, wide reach - is the one this
    /// tool is most worth running on.
    ///
    /// Sixty-four is eight times ``group(_:using:limit:)``'s default batch size, so five
    /// hundred mutants can be in flight looking for a partner. Beyond that the oldest open
    /// group is closed as it stands: a batch smaller than it might have been, never an
    /// unsound one, because the rule that decides what may share a process is checked
    /// inside the window exactly as it was outside it.
    static let window = 64

    /// The same grouping, and how much work finding it took.
    ///
    /// The count is here so that the cost can be asserted rather than timed. A grouping
    /// that quietly went quadratic would still produce exactly the right batches, so no
    /// test about *what* it produces can catch it; the number of candidate groups examined
    /// is what changes, and unlike a stopwatch it is a deterministic function of the input.
    static func grouping(
        _ mutants: [InstrumentedMutant],
        using coverage: Coverage,
        limit: Int = 8
    ) -> (batches: [Self], examined: Int) {
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
        var examined = 0
        for span in spans {
            // Groups still looking for members, oldest first, and never more than
            // ``window`` of them: a full group is closed the moment it fills and the
            // oldest is closed to make room for a new one. Nothing else appends here, so
            // that ceiling is what makes the scan below cost a bounded amount rather than
            // growing with the catalogue.
            var open: [Group] = []
            for entry in bySpan[span] ?? [] {
                var joined: Int?
                // At most `window` of them, which is what keeps this linear in the
                // catalogue. Unbounded, an entry is compared against every group opened so
                // far - and on a package whose mutants all share one broad test no group
                // is ever joined, so the list grows to the size of the catalogue and the
                // scan with it. Counted rather than timed: four hundred mutants sharing
                // one test cost 79,800 comparisons before the ceiling existed.
                for position in open.indices {
                    examined += 1
                    guard open[position].tests.isDisjoint(with: entry.tests) else { continue }
                    joined = position
                    break
                }
                if let joined {
                    open[joined].mutants.append(entry.mutant)
                    open[joined].tests.formUnion(entry.tests)
                    if open[joined].mutants.count >= limit {
                        batches.append(Self(open[joined].mutants, using: coverage))
                        open.remove(at: joined)
                    }
                    continue
                }
                // Nothing within reach would have it, so it opens a group of its own. If
                // the window is already full, the oldest is closed as it stands: a batch
                // smaller than it might have been, never an unsound one, because what may
                // share a process was checked the same way inside the window as outside it.
                if open.count >= Self.window {
                    batches.append(Self(open[0].mutants, using: coverage))
                    open.removeFirst()
                }
                open.append(Group(mutants: [entry.mutant], tests: entry.tests))
            }
            batches += open.map { Self($0.mutants, using: coverage) }
        }
        return (batches, examined)
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
