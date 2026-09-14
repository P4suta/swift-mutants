// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// One machine's share of a catalogue.
///
/// A mutation run is embarrassingly parallel, and the only thing stopping it from using ten
/// machines is agreeing on who does what. Agreement without communication needs the split
/// to be a function of the mutant alone - not of the order it was found in, not of how many
/// there are, not of which files a run happened to be narrowed to.
///
/// The identity is already that function. It is content-addressed, so it is the same on
/// every machine and the same next week; and it is a SHA-256, so its bits are uniform and
/// dividing by them divides evenly. Splitting by position instead would mean that adding
/// one mutant to one file moved every mutant after it to a different machine - and every
/// answer those machines had already worked out with them.
public struct Shard: Sendable, Hashable, CustomStringConvertible {

    /// Which share this is, counted from one because that is how people count machines.
    public let index: Int

    /// How many shares there are.
    public let count: Int

    /// One share of `count`, or nothing if that is not a share.
    public init?(_ index: Int, of count: Int) {
        guard count >= 1, index >= 1, index <= count else { return nil }
        self.index = index
        self.count = count
    }

    /// Whether this share holds the mutant with that identity.
    public func holds(_ identity: Digest) -> Bool {
        Self.owner(of: identity, among: count) == index
    }

    /// Which share holds a mutant.
    ///
    /// The leading eight bytes of the digest, read as one number. Eight rather than all
    /// thirty-two because that is already far more entropy than any catalogue needs, and
    /// one rather than the sum of them because a sum of bytes is not uniform.
    static func owner(of identity: Digest, among count: Int) -> Int {
        var value: UInt64 = 0
        for byte in identity.bytes.prefix(8) { value = (value << 8) | UInt64(byte) }
        return Int(value % UInt64(count)) + 1
    }

    /// How a person writes it, and how a report carries it.
    public var description: String { "\(index)/\(count)" }
}
