// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Runs a list of work a few items at a time, each holding a token nobody else holds.
///
/// A worker token is how a copy of the suite says which copy it is. A non-hermetic suite
/// keys its database, its port and its temporary directory on it; the Xcode path hangs a
/// derived-data directory off it; the prober names its log after it. So the one thing that
/// must never happen is two live workers with the same token, and what happens when it does
/// is not a crash: it is a suite that loses a fixture underneath it, which fails, and a
/// failure under a mutant is a kill. The collision reports itself as detection.
///
/// This exists as a type because both phases that start test processes need it and both got
/// it wrong the same way - a token taken from the position of the work rather than from
/// which worker is free. Work starts as earlier work finishes and it does not finish in
/// order, so `position % jobs` hands item `jobs` the token of item 0 the moment *any* of the
/// first batch finishes, and item 0 is usually not the one that did. Written twice, it was
/// wrong twice; written once, a caller can only get it wrong by not using it.
struct WorkerPool: Sendable {

    /// How many run at once.
    let jobs: Int

    init(jobs: Int) { self.jobs = max(1, jobs) }

    /// Runs `body` over every item, `jobs` at a time, and hands the answers back in the
    /// order the items were given.
    ///
    /// The order is restored rather than observed. Which worker finishes first is a fact
    /// about the machine, and a report that changed shape because a machine was busy could
    /// not be diffed against yesterday's.
    ///
    /// `asEachFinishes` is called once per item as its answer arrives, in whatever order
    /// they arrive, with the position it came from. It is for showing somebody that
    /// something is happening, so it is given the answer rather than a count.
    func run<Work: Sendable, Answer: Sendable>(
        over work: [Work],
        each body: @escaping @Sendable (Work, Int) async -> Answer,
        asEachFinishes finished: (Int, Answer) -> Void = { _, _ in }
    ) async -> [Answer] {
        guard !work.isEmpty else { return [] }
        var slots: [Answer?] = Array(repeating: nil, count: work.count)

        await withTaskGroup(of: Done<Answer>.self) { group in
            var next = 0

            // The tokens nobody is holding. Most recently returned first, because that
            // worker's scratch directory is the one whose build products and caches are
            // warm. Which token an item gets is not visible in any answer - a token names
            // a directory, not anything a verdict depends on - so taking the warm one
            // costs no determinism.
            var free = Array((0..<jobs).reversed())

            // One task per worker to begin with, and one more started for each that
            // finishes. The alternative - every item as a task at once - would have the
            // task group holding a task per item, and on a package of any size that is a
            // lot of nothing waiting to start.
            while next < work.count, let token = free.popLast() {
                let position = next
                group.addTask {
                    Done(
                        position: position,
                        token: token,
                        answer: await body(work[position], token)
                    )
                }
                next += 1
            }
            while let done = await group.next() {
                slots[done.position] = done.answer
                finished(done.position, done.answer)
                free.append(done.token)
                guard next < work.count, let token = free.popLast() else { continue }
                let position = next
                group.addTask {
                    Done(
                        position: position,
                        token: token,
                        answer: await body(work[position], token)
                    )
                }
                next += 1
            }
        }

        // Total by construction: every position is given to exactly one task and every
        // task writes the position it was given. The optional is how the slots are made,
        // not a case a caller has to think about.
        return slots.compactMap { $0 }
    }

    /// A finished item: where its answer goes, and the token it is giving back.
    ///
    /// The token travels with the answer because it has to be returned by whoever observes
    /// the completion, and the only thing that observes a completion is the loop reading
    /// this. A task group hands back values, not identities, so a token that was not in the
    /// value would have to be guessed at from the position - which is the mistake this type
    /// exists to have already made once.
    private struct Done<Answer: Sendable>: Sendable {
        let position: Int
        let token: Int
        let answer: Answer
    }
}
