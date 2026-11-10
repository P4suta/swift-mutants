// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsCore

enum Runtime {
    static func token(for path: WorkspaceRelativePath, digest: Digest) -> String {
        String(
            DigestBuilder().adding("swift-mutants/runtime-token")
                .adding(path.rendered).adding(digest).finalize().hexadecimal.prefix(12))
    }

    static func guardCall(token: String, index: UInt32) -> String {
        "__sm_\(token)(\(marker(token: token, index: index)))"
    }

    static func marker(token: String, index: UInt32) -> String {
        "\(index) /*sm:\(token):\(index)*/"
    }

    static func source(token: String) -> String {
        """

        // swift-mutants runtime.
        @usableFromInline internal let __sm_active_\(token): UInt32? = {
            #if hasFeature(StrictMemorySafety)
                guard let raw = unsafe getenv("SWIFT_MUTANTS_ACTIVE") else { return nil }
                let text = unsafe String(cString: raw)
            #else
                guard let raw = getenv("SWIFT_MUTANTS_ACTIVE") else { return nil }
                let text = String(cString: raw)
            #endif
            return UInt32(text)
        }()
        @inline(__always) @usableFromInline internal func __sm_\(token)(_ index: UInt32) -> Bool {
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
