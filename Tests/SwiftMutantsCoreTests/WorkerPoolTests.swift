// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsTestKit
import Synchronization
import Testing

@testable import SwiftMutantsCore

/// The pool both phases that start test processes take their worker tokens from.
///
/// The invariant is written here once because it was got wrong twice in the same way, and
/// the suites for the scheduler and the prober each assert that they take their tokens from
/// here rather than rolling their own. Three tests rather than one, because "the pool is
/// right" and "this caller uses the pool" are different claims and only the second one
/// catches a caller going back to arithmetic.
@Suite("Worker pool")
struct WorkerPoolTests {

    /// Two jobs and three items, with the first held open until the third has started.
    ///
    /// The third is the one that took `2 % 2 == 0` under the arithmetic that used to
    /// decide this - the token of a worker that is still running, because the *second* is
    /// what finished and freed a slot. Released by arrival rather than by a clock, so the
    /// test is the same on a loaded machine as on an idle one and it terminates whether the
    /// pool is right or wrong.
    @Test("never hands a token to a second worker while the first still holds it")
    func tokensAreNotSharedWhileLive() async {
        let watch = TokenWatch(releasingAfter: 3)
        let answers = await WorkerPool(jobs: 2).run(over: [0, 1, 2]) { item, token in
            watch.arrive(token)
            if item == 0 { await watch.waitForTheRest() }
            watch.leave(token)
            return item * 10
        }

        #expect(answers == [0, 10, 20])
        #expect(
            watch.collided.isEmpty,
            "tokens \(watch.collided.sorted()) were held by two workers at once")
    }

    /// The other half of the same property, and the reason a token is not simply the
    /// position: a run of ten thousand mutants must not want ten thousand scratch
    /// directories. Tokens are a pool of `jobs`, taken and given back.
    @Test("hands out no token outside the pool it was given")
    func tokensStayInThePool() async {
        let watch = TokenWatch(releasingAfter: 9)
        _ = await WorkerPool(jobs: 2).run(over: Array(0..<9)) { item, token in
            watch.arrive(token)
            if item == 0 { await watch.waitForTheRest() }
            watch.leave(token)
            return item
        }
        #expect(watch.used.isSubset(of: [0, 1]), "used tokens \(watch.used.sorted())")
    }

    /// Which worker finishes first is a fact about the machine. A report that changed shape
    /// because a machine was busy could not be diffed against yesterday's, so the answers
    /// come back where they went in.
    @Test("hands the answers back in the order the work was given")
    func keepsTheOrder() async {
        // Three arrivals, because the one that waits never arrives: it is the item held
        // open until the others have finished, so completion order is certainly not the
        // order the work was given in.
        let watch = TokenWatch(releasingAfter: 3)
        let answers = await WorkerPool(jobs: 3).run(over: ["a", "b", "c", "d"]) { item, _ in
            if item == "a" {
                await watch.waitForTheRest()
            } else {
                watch.arrive(0)
                watch.leave(0)
            }
            return item.uppercased()
        }
        #expect(answers == ["A", "B", "C", "D"])
    }

    /// Every item is answered, including the ones that had to wait for a free token.
    @Test("answers every item even when there are more than there are workers")
    func answersEverything() async {
        let answers = await WorkerPool(jobs: 2).run(over: Array(0..<25)) { item, _ in item }
        #expect(answers == Array(0..<25))
    }

    /// Told as they arrive rather than at the end, because a phase that says nothing for
    /// twenty minutes and a phase that has died are the same silence from outside.
    @Test("says which item finished as each one does")
    func reportsAsTheyFinish() async {
        let seen = Mutex<[Int]>([])
        _ = await WorkerPool(jobs: 2).run(
            over: Array(0..<6),
            each: { item, _ in item },
            asEachFinishes: { position, _ in seen.withLock { $0.append(position) } }
        )
        #expect(Set(seen.withLock { $0 }) == Set(0..<6))
    }

    @Test("does nothing at all when there is nothing to do")
    func nothingToDo() async {
        let answers = await WorkerPool(jobs: 4).run(over: [Int]()) { item, _ in item }
        #expect(answers.isEmpty)
    }

    /// A pool of no workers is a pool that would never start anything. One is the smallest
    /// number that makes progress, and a caller asking for none has said something about
    /// its configuration rather than asked for a run that hangs.
    @Test("runs one at a time when asked for fewer workers than one")
    func neverFewerThanOne() async {
        let answers = await WorkerPool(jobs: 0).run(over: [1, 2, 3]) { item, token in
            #expect(token == 0)
            return item
        }
        #expect(answers == [1, 2, 3])
    }
}
