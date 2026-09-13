// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// SHA-256, as specified by FIPS 180-4.
///
/// This is implemented here rather than imported, and the reason is stability rather than
/// preference. A mutant's identity *is* a digest: it decides which cached outcome applies,
/// which expectation in somebody's configuration is still valid, and which shard a mutant
/// lands in. An identity that changed because a dependency was upgraded would invalidate
/// all of that silently, in every project using the tool, with nothing in the output
/// saying so. The sibling projects write their own glob engine for exactly this reason —
/// "mutant IDs must not depend on which one is installed" — and the argument applies with
/// more force to the hash itself.
///
/// It also keeps ``SwiftMutantsCore`` free of dependencies, which is what lets the unit
/// tier build in the time an inner loop can afford.
///
/// This is content addressing, not security: the value is used to name things, never to
/// authenticate them. The implementation is pinned to the published FIPS 180-4 vectors, so
/// the correctness question is closed rather than a matter of trust.
public struct SHA256: Sendable {

    private var state: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]

    /// The bytes of the block being filled, and how many of them are real.
    ///
    /// A fixed window with a count, rather than an array that grows and is drained,
    /// because draining from the front of an `Array` is linear and this runs over whole
    /// source files.
    private var block = [UInt8](repeating: 0, count: 64)
    private var blockCount = 0

    /// Total message length in bytes, which the padding encodes as a bit count.
    private var messageLength: UInt64 = 0

    /// The message schedule, kept across blocks.
    ///
    /// Allocating it per block costs one heap allocation every sixty-four bytes, which on
    /// a source tree is the difference between hashing at a few megabytes a second and
    /// hashing at a useful rate. It is fully overwritten on each use.
    private var schedule = [UInt32](repeating: 0, count: 64)

    /// Creates a hasher with the FIPS 180-4 initial state.
    public init() {}

    /// Adds more of the message.
    ///
    /// Feeding the same bytes in any number of pieces produces the same digest, which is
    /// what lets a caller stream a file without its chunking becoming part of the answer.
    public mutating func update(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            block[blockCount] = byte
            blockCount += 1
            messageLength &+= 1
            if blockCount == 64 {
                compress()
                blockCount = 0
            }
        }
    }

    /// Finishes the message and returns its digest.
    public consuming func finalize() -> Digest {
        let bitLength = messageLength &* 8

        // A single 1 bit, then zeros, until eight bytes are left for the length, then
        // the length itself. Written straight into the block rather than through
        // `update`, which would count the padding towards the length being encoded.
        var padding: [UInt8] = [0x80]
        while (blockCount + padding.count) % 64 != 56 {
            padding.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padding.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        for byte in padding {
            block[blockCount] = byte
            blockCount += 1
            if blockCount == 64 {
                compress()
                blockCount = 0
            }
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for word in state {
            bytes.append(UInt8(truncatingIfNeeded: word >> 24))
            bytes.append(UInt8(truncatingIfNeeded: word >> 16))
            bytes.append(UInt8(truncatingIfNeeded: word >> 8))
            bytes.append(UInt8(truncatingIfNeeded: word))
        }
        return Digest(unchecked: bytes)
    }

    /// One application of the FIPS 180-4 compression function to the filled block.
    ///
    /// The working variables are named `a` through `h`, and the schedule terms `s0` and
    /// `s1`, because FIPS 180-4 names them that. Renaming them would make the one thing
    /// a reader needs to do with this function - hold it against the specification line
    /// by line - materially harder, which is a worse outcome than a short identifier.
    private mutating func compress() {
        // swiftlint:disable identifier_name
        for index in 0..<16 {
            let base = index * 4
            schedule[index] =
                UInt32(block[base]) << 24 | UInt32(block[base + 1]) << 16
                | UInt32(block[base + 2]) << 8 | UInt32(block[base + 3])
        }
        for index in 16..<64 {
            let s0 =
                Self.rotateRight(schedule[index - 15], 7)
                ^ Self.rotateRight(schedule[index - 15], 18) ^ (schedule[index - 15] >> 3)
            let s1 =
                Self.rotateRight(schedule[index - 2], 17)
                ^ Self.rotateRight(schedule[index - 2], 19) ^ (schedule[index - 2] >> 10)
            schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for index in 0..<64 {
            let sum1 = Self.rotateRight(e, 6) ^ Self.rotateRight(e, 11) ^ Self.rotateRight(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ sum1 &+ choose &+ Self.roundConstants[index] &+ schedule[index]
            let sum0 = Self.rotateRight(a, 2) ^ Self.rotateRight(a, 13) ^ Self.rotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sum0 &+ majority

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
        // swiftlint:enable identifier_name
    }

    private static func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    /// The first thirty-two bits of the fractional parts of the cube roots of the first
    /// sixty-four primes, as FIPS 180-4 tabulates them.
    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}
