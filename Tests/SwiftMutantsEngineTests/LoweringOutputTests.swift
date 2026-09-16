// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore
import SwiftMutantsTCE
import Testing

@testable import SwiftMutantsEngine

/// What counts as an answer from a lowering compile.
///
/// The equivalence pass hashes what `swiftc -emit-sil` printed, and a mutant whose hash
/// equals the original's is reported as one no test could ever catch. So the question of
/// whether the compiler said anything at all is the whole of this pass's honesty: a
/// fingerprint taken from nothing is a fingerprint that is wrong in the one direction this
/// tool must never be wrong in.
@Suite("What a lowering compile has to have said")
struct LoweringOutputTests {

    static let sil = Array(
        """
        sil_stage canonical
        sil @$s7Subject5scaleyS2iF : $@convention(thin) (Int) -> Int {
        bb0(%0 : $Int):
          return %0
        }
        """.utf8)

    @Test("reads a fingerprint out of what the compiler printed")
    func readsWhatIsThere() {
        #expect(Lowering.fingerprint(of: Self.sil, complete: true) != nil)
    }

    /// Measured, not supposed. `swiftc -explicit-module-build -emit-sil -o -` against a
    /// module cache it has to build exits 0 and prints *nothing*, and the second run
    /// against the same cache prints the SIL. The equivalence pass took the original's
    /// fingerprint on the very first compile into a fresh cache, so the original was the
    /// digest of an empty string - which nothing could ever equal, and nothing ever did.
    @Test("refuses to fingerprint a compile that printed nothing")
    func refusesSilence() {
        #expect(Lowering.fingerprint(of: [], complete: true) == nil)
    }

    /// Output is captured up to a limit, and a module's lowered form is easily larger. Two
    /// mutants whose difference lies past the limit have the same head - so hashing the
    /// head would report a real survivor as a mutant nothing could catch.
    @Test("refuses to fingerprint output that did not all fit")
    func refusesAHead() {
        #expect(Lowering.fingerprint(of: Self.sil, complete: false) == nil)
    }
}
