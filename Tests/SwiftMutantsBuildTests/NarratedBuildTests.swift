// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsBuild

/// Reading the same plan from a build that narrates itself.
///
/// SwiftPM's build system stopped writing `debug.yaml`. Nothing announced it: the manifest
/// is simply not there, `BuildManifest(parsing:)` reads nothing, and the caller falls back
/// to building the whole package every round - which is correct, silent, and the thing the
/// per-module driver exists to avoid. Seven integration tests found it; no unit test could
/// have, because they all handed the parser a manifest.
///
/// What the new build system does write is the same command, in the middle of a verbose
/// build: one `builtin-SwiftDriver -- <swiftc> ...` line per module, holding the invocation
/// it is about to run. That is the same fact from a different mouth.
///
/// Escaped rather than quoted, which is the part worth a test of its own: it writes
/// `-D_X\=1` and `plugins/testing\#/usr/bin/swift-plugin-server`, so a splitter that broke
/// on spaces alone would hand the compiler a `\` it cannot read.
@Suite("Build manifest, from a verbose build")
struct VerboseBuildManifestTests {

    /// One target's line, cut to the arguments that matter, with the escaping intact.
    static let narration = """
        Build description signature: 2a742e5ef672048795d6ecc3e168f1e2
        Compiling Swift Module 'Core' (1 sources)
            builtin-SwiftDriver -- /usr/bin/swiftc -module-name Core -Onone \
        @/pkg/.build/out/Core.SwiftFileList -DSWIFT_PACKAGE -Xcc -D_LIBCPP\\=DEBUG \
        -external-plugin-path /plugins/testing\\#/usr/bin/swift-plugin-server \
        -swift-version 6 -I /pkg/.build/out/Products/Debug -c
        Link Core
            /usr/bin/ld -o /pkg/.build/out/Products/Debug/Core.o
        """

    static func fileLists(_ path: String) -> String? {
        path == "/pkg/.build/out/Core.SwiftFileList"
            ? "/pkg/Sources/Core/A.swift\n/pkg/Sources/Core/B.swift\n" : nil
    }

    @Test("reads a module's compile command out of a narrated build")
    func readsTheCommand() throws {
        let manifest = try #require(
            BuildManifest(parsingVerboseBuild: Self.narration, readingFileList: Self.fileLists))
        let module = try #require(manifest.modules.first)
        #expect(manifest.modules.count == 1)
        #expect(module.name == "Core")
        #expect(module.arguments.first == "/usr/bin/swiftc")
        #expect(module.arguments.contains("@/pkg/.build/out/Core.SwiftFileList"))
    }

    /// The escapes are the build system's, not the compiler's. A word handed on with the
    /// backslash still in it is an argument no compiler accepts, and the error it produces
    /// is about neither the package nor any mutant in it.
    @Test("unescapes what the narration escaped")
    func unescapes() throws {
        let manifest = try #require(
            BuildManifest(parsingVerboseBuild: Self.narration, readingFileList: Self.fileLists))
        let module = try #require(manifest.modules.first)
        #expect(module.arguments.contains("-D_LIBCPP=DEBUG"), "\(module.arguments)")
        #expect(
            module.arguments.contains("/plugins/testing#/usr/bin/swift-plugin-server"),
            "\(module.arguments)")
        #expect(!module.arguments.contains { $0.contains("\\") }, "\(module.arguments)")
    }

    /// Which files a module holds decides which modules a set of instrumented paths
    /// touches. The narration names a response file rather than the sources, so a parser
    /// that stopped at the line would leave every module claiming to hold nothing - and a
    /// set of paths belonging to no module sends the whole question to a real build.
    @Test("follows the response file to the sources")
    func followsTheResponseFile() throws {
        let manifest = try #require(
            BuildManifest(parsingVerboseBuild: Self.narration, readingFileList: Self.fileLists))
        let module = try #require(manifest.modules.first)
        #expect(module.sources == ["/pkg/Sources/Core/A.swift", "/pkg/Sources/Core/B.swift"])
    }

    /// Narration with no compile in it is refused rather than returned empty, for the same
    /// reason an unreadable manifest is: an empty plan and a plan nobody could read look
    /// the same to a caller and mean opposite things.
    @Test("refuses a narration that describes no Swift module")
    func refusesNarrationWithoutModules() {
        let read: (String) -> String? = { _ in nil }
        #expect(BuildManifest(parsingVerboseBuild: "Build complete!", readingFileList: read) == nil)
    }
}
