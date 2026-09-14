// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsTCE

/// What a program compiles to, as one number.
///
/// A mutant the compiler turns into the same program as the original cannot be caught by
/// any test, ever. It is not a hole in somebody's suite; it is a mutant that should never
/// have been made, and every run reports it as a survivor and wastes somebody's afternoon
/// again. The compiler already knows - `x * 1` and `x` are the same instruction sequence at
/// `-O` - and this is how it is asked.
///
/// Everything here is about what may be ignored. SIL carries source locations, debug scopes
/// and comments, and every one of them changes when a byte moves - so a fingerprint that
/// kept them would say every mutant is different from the original, which is true of the
/// text and false of the program.
@Suite("SIL fingerprints")
struct FingerprintTests {

    static let body = """
        sil_scope 1 { loc "a.swift":1:8 parent @$s1T5scaleyS2iF }
        sil @$s1T5scaleyS2iF : $@convention(thin) (Int) -> Int {
        bb0(%0 : $Int):
          debug_value %0 : $Int, let, name "x", argno 1, loc "a.swift":1:20, scope 1
          return %0 : $Int                                // id: %2
        } // end sil function '$s1T5scaleyS2iF'
        """

    /// The same program written at a different place in a file is the same program.
    @Test("ignores where in the file the code was")
    func ignoresLocations() {
        let moved = Self.body.replacingOccurrences(of: "a.swift\":1:", with: "a.swift\":9:")
        #expect(Fingerprint.of(Self.body) == Fingerprint.of(moved))
    }

    @Test("ignores the comments the compiler writes into it")
    func ignoresComments() {
        let annotated = Self.body.replacingOccurrences(of: "// id: %2", with: "// id: %77")
        #expect(Fingerprint.of(Self.body) == Fingerprint.of(annotated))
    }

    /// Debug scopes are numbered in the order they are emitted, so inserting anything
    /// renumbers them all - which says nothing about what the program does.
    @Test("ignores the numbering of debug scopes")
    func ignoresScopes() {
        let renumbered = Self.body
            .replacingOccurrences(of: ", scope 1", with: ", scope 4")
            .replacingOccurrences(of: "sil_scope 1", with: "sil_scope 4")
        #expect(Fingerprint.of(Self.body) == Fingerprint.of(renumbered))
    }

    /// And the thing it must never ignore: the instructions.
    @Test("does not ignore what the program does")
    func noticesInstructions() {
        let different = Self.body.replacingOccurrences(
            of: "return %0 : $Int", with: "return %1 : $Int")
        #expect(Fingerprint.of(Self.body) != Fingerprint.of(different))
    }

    /// Which values an instruction refers to is what the program does, so the numbering of
    /// values is kept even though the numbering of scopes is not.
    @Test("does not ignore which value an instruction names")
    func noticesValueNames() {
        let swapped = """
            bb0(%0 : $Int, %1 : $Int):
              return %0 : $Int
            """
        let other = """
            bb0(%0 : $Int, %1 : $Int):
              return %1 : $Int
            """
        #expect(Fingerprint.of(swapped) != Fingerprint.of(other))
    }

    /// The same program written two ways that differ only in what is ignored.
    @Test("is the same for the same program")
    func deterministic() {
        let spaced = Self.body
            .replacingOccurrences(of: "a.swift\":1:", with: "a.swift\":5:")
            .replacingOccurrences(of: "// id: %2", with: "// id: %9")
        #expect(Fingerprint.of(Self.body) == Fingerprint.of(spaced))
    }

    /// Whitespace is how a compiler lays out text, not what it decided.
    @Test("ignores how the text was spaced")
    func ignoresSpacing() {
        let respaced = Self.body.replacingOccurrences(of: "  return", with: "      return")
        #expect(Fingerprint.of(Self.body) == Fingerprint.of(respaced))
    }
}
