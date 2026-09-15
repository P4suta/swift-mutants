// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTempOwner

/// Compiles a run left behind, read out of what the machine is running.
///
/// `swift-mutants` puts its children in a process group of their own, so a Ctrl-C at the
/// terminal does not take a compiler down in the middle of writing a module. The cost of
/// that isolation is that a `swift-mutants` which is killed leaves its compiles running, and
/// the deadline that would have stopped them dies with the parent.
///
/// Reaping them on a signal is not built, and that is deliberate: it needs a preallocated
/// lock-free registry, and a careless version is worse than the leak because a process id is
/// reused. The trouble with a deliberate decision written in a commit message is that the
/// person who meets a compiler which has been running for five hours is not reading commit
/// messages. Measured: a `swift-frontend` from an interrupted run of this tool's own
/// integration tier spent five hours and seventeen minutes on one file, on a machine whose
/// owner could not see why it was busy.
///
/// So `doctor` says. It does not kill anything - what to do about somebody's process is
/// theirs to decide, and a tool that reached for a process it did not start would be a worse
/// thing than the leak.
///
/// Read out of `ps` rather than out of anything this tool kept, because the run that would
/// have kept it is the run that is gone.
enum StrayCompiles {

    /// One compile, still running, working inside one of this tool's trees.
    struct Found: Sendable, Hashable {

        /// What to look at, or to stop.
        let pid: Int

        /// How long it has been running, as `ps` writes it.
        let elapsed: String

        /// The scratch directory it is working in, which says which run left it.
        let tree: String

        /// How long it has been running, in seconds, for ordering.
        let seconds: Int
    }

    /// The compiles in one of this tool's trees, oldest first.
    ///
    /// Oldest first because the only one worth acting on is the one that has been there
    /// long enough not to be a run somebody started a moment ago - and this cannot tell
    /// those apart, so it puts the evidence in the order that makes the difference obvious
    /// rather than guessing.
    ///
    /// Reads nothing out of anything it does not understand. `ps` is a program that might
    /// not be there and might say something this cannot parse, and a doctor that fell over
    /// while telling somebody about their machine would be worse than one that stays quiet.
    static func reading(_ listing: String) -> [Found] {
        var found: [Found] = []
        for line in listing.split(separator: "\n").dropFirst() {
            let fields = line.split(
                separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int(fields[0]) else { continue }
            guard let tree = Self.tree(in: String(fields[2])) else { continue }
            found.append(
                Found(
                    pid: pid,
                    elapsed: String(fields[1]),
                    tree: tree,
                    seconds: Self.seconds(of: String(fields[1]))
                ))
        }
        return found.sorted { ($0.seconds, $0.pid) > ($1.seconds, $1.pid) }
    }

    /// The scratch directory a command is working in, if it is one of this tool's.
    ///
    /// Matched on the prefix every one of them carries, which is the one thing a leftover
    /// compile is certain to have in its arguments: the tree it is reading from.
    private static func tree(in command: String) -> String? {
        guard let start = command.range(of: TempOwner.prefix) else { return nil }
        let rest = command[start.lowerBound...]
        let end = rest.firstIndex(of: "/") ?? rest.endIndex
        return String(rest[..<end])
    }

    /// An elapsed time as `ps` writes it - `[[dd-]hh:]mm:ss` - in seconds.
    ///
    /// Zero for anything it cannot read, which orders it last rather than making it look
    /// like the oldest thing on the machine.
    static func seconds(of text: String) -> Int {
        let parts = text.split(separator: "-", maxSplits: 1)
        let days = parts.count == 2 ? Int(parts[0]) ?? 0 : 0
        let clock = parts.count == 2 ? parts[1] : Substring(text)
        // The clock on its own first, then the days. Folding the days in before the clock
        // would multiply them by sixty once per field, which is a number nobody would
        // recognise as wrong until it sorted a compile from this morning above one from
        // last week.
        var clockSeconds = 0
        for field in clock.split(separator: ":") {
            clockSeconds = clockSeconds * 60 + (Int(field) ?? 0)
        }
        return days * 86400 + clockSeconds
    }
}
