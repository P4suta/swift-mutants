// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore

/// The few lines appended to an instrumented file so that its guards have something to ask.
///
/// File-local, and that is the decision that makes an Xcode project as easy as a package:
/// nothing has to be added to a manifest, no target membership has to be worked out, and
/// `project.pbxproj` is never touched. The cost is one lazily-initialised global per
/// mutated file, which Swift initialises through `swift_once` and is therefore thread-safe
/// without anybody arranging it.
///
/// The environment is read **once**. Muter evaluates
/// `ProcessInfo.processInfo.environment[...]` inside every guard, which materialises a
/// dictionary from `environ` on each evaluation; a guard inside a loop pays that every time
/// round. Here the read happens in the global's initialiser and a guard is an integer
/// compare.
enum Runtime {

    /// The environment variable that says which mutant is awake.
    static let activationVariable = "SWIFT_MUTANTS_ACTIVE"

    /// The environment variable that says where to record what was reached.
    ///
    /// Set for a probe run and unset for every other. A guard is the right place to record
    /// from because a guard is evaluated exactly when its site is: no extra expression, no
    /// change to what the compiler has to type-check, and nothing that can be reached
    /// without the mutant having been reachable.
    static let probeVariable = "SWIFT_MUTANTS_PROBE"

    /// A per-file suffix, so two instrumented files in one module cannot collide.
    ///
    /// Derived from the path and the file's digest rather than from a counter, so that
    /// instrumenting the same file twice produces the same names and two instrumented trees
    /// can be compared.
    static func token(for path: WorkspaceRelativePath, digest: Digest) -> String {
        String(
            DigestBuilder()
                .adding("swift-mutants/runtime-token")
                .adding(path.rendered)
                .adding(digest)
                .finalize()
                .hexadecimal
                .prefix(12)
        )
    }

    /// The call a guard makes.
    static func guardCall(token: String, index: UInt32) -> String {
        "__sm_\(token)(\(marker(token: token, index: index)))"
    }

    /// The literal a guard passes, and what the activation proof looks for.
    ///
    /// The index is spelled with a suffix so that it is a string a binary can be searched
    /// for: a bare `3` would appear in any program, while `3 as UInt32` does not survive
    /// compilation as text. The suffix makes the marker a token the optimiser keeps in the
    /// symbol table of the guard's own function.
    static func marker(token: String, index: UInt32) -> String {
        "\(index) /*sm:\(token):\(index)*/"
    }

    /// The runtime, ready to append.
    ///
    /// Everything in it is `@usableFromInline internal` rather than `private`, which is one
    /// decision and not an obvious one. Swift will not let an `@inlinable` function
    /// reference a private symbol, so a private guard makes every mutant inside such a
    /// function unbuildable - and they arrive at validation as refusals with no cause a
    /// reader can see, so the score quietly excludes whatever the package decided was hot.
    /// Reported from a real package: seventeen `@inlinable` functions across three files,
    /// all of them the inner loops of a layout solver, which is exactly the code somebody
    /// cares most about being right.
    ///
    /// The cost is module-wide visibility instead of file-wide, and it is not a real one:
    /// the name carries a digest of the file's path and contents, so two instrumented files
    /// in one module cannot collide.
    ///
    /// The import is **selective and trailing**, which is two more decisions.
    ///
    /// Trailing, because an import at the top would push every line of the file down by one
    /// and a coverage profile taken from the instrumented build would stop lining up with
    /// the file the user wrote. Swift permits an import at file scope anywhere.
    ///
    /// Selective, because `import Darwin` brings the whole C library into a file that may
    /// not have asked for it, and a name the file already resolves one way could become
    /// ambiguous. `import func Darwin.getenv` brings in one function - and that function is
    /// already named by the guard above it, so nothing else in the file can be affected.
    static func source(token: String, count: Int, base: UInt32 = 0) -> String {
        """

        // swift-mutants runtime, appended so that every line above keeps its number.
        // \(count) mutant\(count == 1 ? "" : "s") live in this file, one awake at a time.
        \(activation(token: token))
        \(probing(token: token, count: count, base: base))
        @inline(__always) @usableFromInline internal func __sm_\(token)(_ index: UInt32) -> Bool {
            if __sm_probe_\(token) >= 0 { __sm_record_\(token)(index) }
            let slot = Int(index) >> 6
            guard slot < __sm_awake_\(token).count else { return false }
            return (__sm_awake_\(token)[slot] >> UInt64(index & 63)) & 1 == 1
        }
        \(imports)
        """
    }

    /// Which mutant is awake, read once.
    ///
    /// The environment is read in a global's initialiser rather than inside each guard, so
    /// a guard in a loop is an integer compare. Muter evaluates
    /// `ProcessInfo.processInfo.environment[...]` per guard, which materialises a
    /// dictionary from `environ` every time round.
    private static func activation(token: String) -> String {
        """
        // A set rather than one number, because several mutants can be awake at once when
        // no test reaches more than one of them - which is most of them, and which is what
        // turns one process per mutant into one process per handful. Read once into a bit
        // array, so a guard stays a shift and a mask rather than becoming a search.
        //
        // Spelled both ways, chosen at compile time. `getenv` returns a pointer, so a
        // package built with -strict-memory-safety warns unless the call is marked - and
        // one built without it warns about a mark that was not needed. Generated code has
        // no business producing a warning either way, and a package that turns warnings
        // into errors would not build at all.
        @usableFromInline internal let __sm_awake_\(token): [UInt64] = {
            #if hasFeature(StrictMemorySafety)
                guard let raw = unsafe getenv("\(activationVariable)") else { return [] }
                let text = unsafe String(cString: raw)
            #else
                guard let raw = getenv("\(activationVariable)") else { return [] }
                let text = String(cString: raw)
            #endif
            var bits: [UInt64] = []
            for part in text.split(separator: ",") {
                guard let index = UInt32(part) else { continue }
                let slot = Int(index) >> 6
                while bits.count <= slot { bits.append(0) }
                bits[slot] |= UInt64(1) << UInt64(index & 63)
            }
            return bits
        }()
        """
    }

    /// Writing down which mutants a run reached.
    ///
    /// The file is opened once, in append mode, and never closed: a line written is a line
    /// on disk, so a process that crashes still proves what it got to. One slot per mutant
    /// keeps a site inside a loop to a single line - a racing pair of threads can both
    /// write the same index, which costs a duplicate and nothing else, because the reader
    /// takes a set.
    private static func probing(token: String, count: Int, base: UInt32) -> String {
        """
        @usableFromInline internal let __sm_probe_\(token): Int32 = {
            #if hasFeature(StrictMemorySafety)
                guard let raw = unsafe getenv("\(probeVariable)") else { return -1 }
                return unsafe open(raw, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            #else
                guard let raw = getenv("\(probeVariable)") else { return -1 }
                return open(raw, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            #endif
        }()
        @usableFromInline nonisolated(unsafe) internal var __sm_seen_\(token) = [Bool](
            repeating: false, count: \(count))
        @usableFromInline internal func __sm_record_\(token)(_ index: UInt32) {
            let slot = Int(index) - \(base)
            // Spelled twice, on the setting alone. It carried `&& compiler(>=6.4)` as
            // well, on the belief that 6.3 calls these markers unnecessary - and the first
            // time this was compiled by a 6.3 toolchain, which was the first time it was
            // compiled anywhere but the machine it was written on, 6.3 asked for them:
            // `expression uses unsafe constructs but is not marked with 'unsafe'`, three
            // times, on the branch the version condition had sent it to. Both toolchains
            // want the markers under the setting, so the setting is the whole condition.
            #if hasFeature(StrictMemorySafety)
                guard slot >= 0, unsafe slot < __sm_seen_\(token).count,
                    unsafe !__sm_seen_\(token)[slot]
                else { return }
                unsafe __sm_seen_\(token)[slot] = true
            #else
                guard slot >= 0, slot < __sm_seen_\(token).count, !__sm_seen_\(token)[slot]
                else { return }
                __sm_seen_\(token)[slot] = true
            #endif
            // The array goes straight to `write`, on the implicit conversion that lends a
            // pointer to its storage for the length of the call. Not through
            // `withUnsafeBufferPointer`: that needs a marker of its own under
            // -strict-memory-safety on Swift 6.3 and reports the same marker as covering
            // nothing on 6.4, so there is no one spelling of it that both accept.
            let line = Array("\\(index)\\n".utf8)
            #if hasFeature(StrictMemorySafety)
                _ = unsafe write(__sm_probe_\(token), line, line.count)
            #else
                _ = write(__sm_probe_\(token), line, line.count)
            #endif
        }
        """
    }

    /// The names the runtime needs, brought in selectively and last.
    private static var imports: String {
        """
        #if canImport(Darwin)
            import func Darwin.getenv
            import func Darwin.open
            import func Darwin.write
            import var Darwin.O_APPEND
            import var Darwin.O_CREAT
            import var Darwin.O_WRONLY
        #else
            import func Glibc.getenv
            import func Glibc.open
            import func Glibc.write
            import var Glibc.O_APPEND
            import var Glibc.O_CREAT
            import var Glibc.O_WRONLY
        #endif
        """
    }
}
