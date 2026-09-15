// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// What this tool has kept, so that somebody can see it and stop keeping it.
///
/// A cache exists to be trusted, and the moment somebody stops trusting one is the moment
/// they need to see inside it. There was no way to. The answers live outside the repository
/// under a name that is a digest, which is right - a run must not write into somebody's tree
/// and two packages must not share answers - and it leaves a person who suspects a stale
/// answer with nothing to do but find and delete a directory nobody told them about.
///
/// `--cache off` was the whole escape hatch, and it answers a different question: it says
/// "do not use one this time", not what is in there, how old it is, or how to be rid of it.
///
/// One file per package, so the thing that accumulates is packages. A machine that measured
/// forty repositories last year keeps forty answers files for repositories that may no
/// longer exist - which is what a sweep is for, and why it counts days rather than entries.
/// An answer carries no date of its own, and giving it one would be a schema change to
/// answer a question the file's own timestamp already answers.
public enum CacheInventory {

    /// One file this tool is keeping.
    public struct Entry: Sendable, Hashable {

        /// Where it is.
        public let file: URL

        /// How big it is.
        public let bytes: Int

        /// When it was last written.
        public let modified: Date

        /// Records one kept file.
        public init(file: URL, bytes: Int, modified: Date) {
            self.file = file
            self.bytes = bytes
            self.modified = modified
        }
    }

    /// Where everything this tool keeps for a package lives.
    public static func home() -> URL {
        let root =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appending(path: "swift-mutants")
    }

    /// Everything kept there, newest first.
    public static func entries(in home: URL) -> [Entry] {
        let found =
            (try? FileManager.default.contentsOfDirectory(
                at: home,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
        return
            found
            .compactMap { file in
                let values = try? file.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard let modified = values?.contentModificationDate else { return nil }
                return Entry(file: file, bytes: values?.fileSize ?? 0, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
    }

    /// The ones that have not been written to in this many days.
    ///
    /// The boundary belongs to the newer side: a cache written exactly thirty days ago is
    /// thirty days old rather than thirty-one, and a sweep of thirty days that removed it
    /// would remove something the person asked to keep.
    ///
    /// Nought does not mean all of them, which is the other reading and the dangerous one:
    /// a cache written this instant is not older than nought days. A mistyped sweep removes
    /// nothing rather than everything, and `clean` is the way to say "all of mine" - a
    /// different sentence, which should look like one. A negative number is not an age and
    /// removes nothing for the same reason.
    public static func stale(_ entries: [Entry], olderThan days: Int, now: Date) -> [Entry] {
        guard days >= 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { $0.modified < cutoff }
    }

    /// What is kept, in the units a person thinks in.
    public static func summary(of entries: [Entry], now: Date) -> String {
        guard !entries.isEmpty else { return "nothing is kept here yet." }
        let bytes = entries.reduce(0) { $0 + $1.bytes }
        let oldest = entries.map(\.modified).min() ?? now
        let days = Int(now.timeIntervalSince(oldest) / 86_400)
        return """
            \(entries.count) file\(entries.count == 1 ? "" : "s"), \(Self.size(bytes)), \
            the oldest written \(days) day\(days == 1 ? "" : "s") ago.
            """
    }

    /// A count of bytes as somebody would say it.
    ///
    /// Written out rather than taken from a formatter, because a formatter's answer depends
    /// on the machine's locale and this is a number in a gate's output as often as in a
    /// terminal.
    static func size(_ bytes: Int) -> String {
        guard bytes >= 1_000_000 else {
            return bytes >= 1_000 ? "\(bytes / 1_000) kB" : "\(bytes) bytes"
        }
        return "\(bytes / 100_000 / 10).\(bytes / 100_000 % 10) MB"
    }
}
