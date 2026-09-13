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
    /// The import is **selective and trailing**, which is two decisions.
    ///
    /// Trailing, because an import at the top would push every line of the file down by one
    /// and a coverage profile taken from the instrumented build would stop lining up with
    /// the file the user wrote. Swift permits an import at file scope anywhere.
    ///
    /// Selective, because `import Darwin` brings the whole C library into a file that may
    /// not have asked for it, and a name the file already resolves one way could become
    /// ambiguous. `import func Darwin.getenv` brings in one function - and that function is
    /// already named by the guard above it, so nothing else in the file can be affected.
    static func source(token: String, count: Int) -> String {
        """

        // swift-mutants runtime, appended so that every line above keeps its number.
        // \(count) mutant\(count == 1 ? "" : "s") live in this file, one awake at a time.
        // The environment is read once here rather than inside each guard, so a guard in a
        // loop is an integer compare rather than a dictionary build.
        private let __sm_active_\(token): UInt32 = {
            guard let raw = getenv("\(activationVariable)"),
                let value = UInt32(String(cString: raw))
            else { return .max }
            return value
        }()
        @inline(__always) private func __sm_\(token)(_ index: UInt32) -> Bool {
            __sm_active_\(token) == index
        }
        #if canImport(Darwin)
            import func Darwin.getenv
        #else
            import func Glibc.getenv
        #endif
        """
    }
}
