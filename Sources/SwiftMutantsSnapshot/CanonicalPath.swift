// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public import Foundation

/// The one spelling of a path that everything agrees on.
///
/// macOS gives the same directory more than one name: `/var`, `/tmp` and `/etc` are
/// symlinks into `/private`, and a run's copy lives under `/var/folders`. Which name a
/// program sees depends on how it got there - the C library's `getcwd`, which is what clang
/// records in its module cache, reports `/private/var/...`, while a path built up from
/// `FileManager.temporaryDirectory` says `/var/...`.
///
/// Disagreeing about it is not cosmetic. The compiler refuses a module cache holding one
/// module under two names, with an error about neither the package nor any mutant in it;
/// and a diagnostic reported against one spelling matches no file recorded under the other,
/// which once left a whole run unable to attribute a single error it was given.
///
/// `Foundation`'s own `resolvingSymlinksInPath()` is not this. It resolves symlinks in the
/// middle of a path but normalises `/private/var` *towards* `/var`, which is the opposite
/// of what the C library does, so a path passed through it still disagrees with `getcwd`.
public enum CanonicalPath {

    /// The path as the operating system itself spells it, or unchanged if it has no answer.
    ///
    /// Unchanged rather than refused: a path that does not exist yet has no canonical form,
    /// and a caller asking about one is better served by the name it already has than by an
    /// error. The names then still agree, because there is only the one.
    public static func of(_ url: URL) -> URL {
        guard let resolved = Self.of(url.path) else { return url }
        return URL(filePath: resolved)
    }

    /// The path as the operating system itself spells it, or nothing if it has no answer.
    public static func of(_ path: String) -> String? {
        // `realpath(path, nil)` allocates the result, which is this function's to free.
        // Every path in and out of it is bytes, and Swift's own `String(cString:)` is the
        // only reader of them.
        //
        // Spelled both ways, because the two toolchains this package supports disagree
        // about the *outer* call. 6.4 reports a marker on `withCString` as covering no
        // unsafe operation; 6.3 requires one. Under `-warnings-as-errors` either
        // disagreement is a build failure rather than a note, so neither spelling works on
        // both and the compiler chooses.
        // Inline in the `guard` rather than bound first: a `let` holding the pointer makes
        // every later mention of it an unsafe expression of its own, which is three more
        // markers for no more safety.
        #if compiler(>=6.4)
        guard let buffer = path.withCString({ unsafe realpath($0, nil) }) else {
            return nil
        }
        #else
        guard let buffer = unsafe path.withCString({ unsafe realpath($0, nil) }) else {
            return nil
        }
        #endif
        defer { unsafe free(buffer) }
        return unsafe String(cString: buffer)
    }
}
