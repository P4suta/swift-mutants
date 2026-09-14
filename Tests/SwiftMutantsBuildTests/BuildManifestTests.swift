// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsBuild

/// Reading the build SwiftPM planned, rather than guessing at it.
///
/// Validation asks one question - would the compiler accept this tree - and the honest way
/// to ask it is per module, because a package is not a pile of files. Each target compiles
/// against its own dependencies with its own search paths, module maps, language mode and
/// upcoming features, and there are forty-odd such arguments per target here. Rebuilding
/// that list by hand is the kind of guess that is wrong on somebody else's package and
/// right on this one.
///
/// SwiftPM has already worked it out. It writes the plan as an llbuild manifest with, for
/// every module, the exact `swiftc` invocation it would run. Reading it is reading the
/// answer instead of recomputing it.
@Suite("Build manifest")
struct BuildManifestTests {

    /// The shape SwiftPM writes, cut down to what matters here.
    static let manifest = """
        client:
          name: basic
        targets:
          "Core-arm64-apple-macosx-debug.module": ["<Core-arm64-apple-macosx-debug.module>"]
        commands:
          "C.Core-arm64-apple-macosx-debug.module":
            tool: shell
            inputs: ["/pkg/Sources/Core/A.swift"]
            outputs: ["/pkg/.build/debug/Core.build/A.swift.o"]
            description: "Compiling Swift Module 'Core' (1 sources)"
            args: ["/usr/bin/swiftc","-module-name","Core","-emit-module","-emit-module-path","/pkg/.build/debug/Modules/Core.swiftmodule","-c","@/pkg/.build/debug/Core.build/sources","-I","/pkg/.build/debug/Modules","-swift-version","6","-Xcc","-g","-package-name","pkg"]
          "C.App-arm64-apple-macosx-debug.module":
            tool: shell
            inputs: ["/pkg/Sources/App/B.swift"]
            outputs: ["/pkg/.build/debug/App.build/B.swift.o"]
            description: "Compiling Swift Module 'App' (1 sources)"
            args: ["/usr/bin/swiftc","-module-name","App","-c","@/pkg/.build/debug/App.build/sources","-I","/pkg/.build/debug/Modules"]
          "C.Core-arm64-apple-macosx-debug.module-link":
            tool: shell
            inputs: ["/pkg/.build/debug/Core.build/A.swift.o"]
            outputs: ["/pkg/.build/debug/libCore.dylib"]
            description: "Linking Core"
            args: ["/usr/bin/swiftc","-emit-library","-o","/pkg/.build/debug/libCore.dylib"]
        """

    @Test("finds every Swift module the package has")
    func findsEveryModule() throws {
        let manifest = try #require(BuildManifest(parsing: Self.manifest))
        #expect(manifest.modules.map(\.name).sorted() == ["App", "Core"])
    }

    /// Linking, copying and C compilation are in the same file and are not questions about
    /// whether Swift accepts a tree.
    @Test("passes over the commands that are not Swift modules")
    func ignoresOtherCommands() throws {
        let manifest = try #require(BuildManifest(parsing: Self.manifest))
        #expect(manifest.modules.count == 2)
        #expect(!manifest.modules.contains { $0.arguments.contains("-emit-library") })
    }

    @Test("keeps the arguments SwiftPM worked out")
    func keepsTheArguments() throws {
        let manifest = try #require(BuildManifest(parsing: Self.manifest))
        let core = try #require(manifest.modules.first { $0.name == "Core" })
        #expect(core.arguments.first == "/usr/bin/swiftc")
        #expect(core.arguments.contains("@/pkg/.build/debug/Core.build/sources"))
    }

    /// A manifest this cannot read is not an error, it is a fallback: the caller builds the
    /// whole package instead, which is slower and always works. Guessing at a shape that
    /// has changed would be the one outcome worse than being slow.
    @Test("refuses what it cannot read rather than guessing")
    func refusesWhatItCannotRead() {
        #expect(BuildManifest(parsing: "") == nil)
        #expect(BuildManifest(parsing: "client:\n  name: basic\n") == nil)
        #expect(
            BuildManifest(parsing: "commands:\n  \"C.X-debug.module\":\n    tool: shell\n") == nil)
    }
}

/// Turning a compile into a question.
///
/// The same arguments, minus everything that writes a file. What is left asks the compiler
/// whether the module is well-typed and lets it answer without producing an object, a
/// module, a header, a dependency file or an index - none of which validation reads, and
/// each of which would have this writing into a tree it is only asking about.
@Suite("A compile as a typecheck")
struct TypecheckArgumentsTests {

    static func typecheck(_ arguments: [String]) -> [String] {
        BuildManifest.Module(name: "M", arguments: arguments).typecheckArguments
    }

    @Test("asks rather than builds")
    func asksRatherThanBuilds() {
        let asked = Self.typecheck(["/usr/bin/swiftc", "-c", "a.swift"])
        #expect(asked.contains("-typecheck"))
        #expect(!asked.contains("-c"))
    }

    /// Machine-readable `line:col`, because attribution is by byte span and the default
    /// style wraps and underlines.
    @Test("asks for diagnostics it can read")
    func asksForReadableDiagnostics() {
        #expect(Self.typecheck(["/usr/bin/swiftc"]).contains("-diagnostic-style=llvm"))
    }

    @Test(
        "drops what would write a file",
        arguments: [
            ["-emit-module"], ["-emit-dependencies"], ["-serialize-diagnostics"],
            ["-emit-module-path", "/pkg/M.swiftmodule"],
            ["-output-file-map", "/pkg/map.json"],
            ["-index-store-path", "/pkg/index"],
            ["-emit-objc-header-path", "/pkg/M-Swift.h"],
        ]
    )
    func dropsWhatWrites(_ flag: [String]) {
        let asked = Self.typecheck(["/usr/bin/swiftc"] + flag + ["-swift-version", "6"])
        #expect(!asked.contains(flag[0]))
        if flag.count == 2 { #expect(!asked.contains(flag[1])) }
        // And the arguments around it survive.
        #expect(asked.contains("-swift-version"))
        #expect(asked.contains("6"))
    }

    /// The one every hand-written version of this gets wrong. `-Xcc` and the word after it
    /// travel together, and that word is clang's, not Swift's - `-Xcc -c` means "compile
    /// only" to clang and has nothing to do with whether swiftc emits an object. Reading it
    /// as swiftc's own `-c` drops it, which leaves a bare `-Xcc` that swallows whatever came
    /// next; the compiler then reports an unexpected input file, a complaint about nothing
    /// in the package, arriving exactly where this tool is deciding what the package
    /// refused. This happened while writing it.
    @Test(
        "never reads a carried argument as one of its own",
        arguments: ["-Xcc", "-Xfrontend", "-Xllvm", "-Xclang-linker"]
    )
    func keepsPassthroughPairsIntact(_ carrier: String) {
        let asked = Self.typecheck([
            "/usr/bin/swiftc", carrier, "-c", "-package-name", "pkg",
        ])
        #expect(asked.contains(carrier))
        #expect(asked.suffix(4) == [carrier, "-c", "-package-name", "pkg"])
    }

    /// The premise: swiftc's own `-c` really is dropped, so the pair above is a different
    /// decision rather than the same one twice.
    @Test("still drops the same flag when nothing is carrying it")
    func dropsTheSameFlagOnItsOwn() {
        #expect(!Self.typecheck(["/usr/bin/swiftc", "-c", "-package-name", "pkg"]).contains("-c"))
    }

    /// Everything a module needs to resolve its imports, which is most of the list.
    @Test("keeps what the module needs to be understood")
    func keepsWhatItNeeds() {
        let asked = Self.typecheck([
            "/usr/bin/swiftc", "-module-name", "Core", "-I", "/pkg/.build/debug/Modules",
            "-swift-version", "6", "-strict-memory-safety",
            "-enable-upcoming-feature", "ExistentialAny",
            "-Xcc", "-fmodule-map-file=/pkg/shim/module.modulemap",
            "@/pkg/.build/debug/Core.build/sources",
        ])
        for kept in [
            "-module-name", "Core", "-I", "/pkg/.build/debug/Modules", "-swift-version", "6",
            "-strict-memory-safety", "-enable-upcoming-feature", "ExistentialAny",
            "-Xcc", "-fmodule-map-file=/pkg/shim/module.modulemap",
            "@/pkg/.build/debug/Core.build/sources",
        ] {
            #expect(asked.contains(kept), "lost \(kept)")
        }
    }

    /// The compiler runs the program, and it must stay the first word.
    @Test("leaves the compiler at the front")
    func compilerStaysFirst() {
        #expect(Self.typecheck(["/usr/bin/swiftc", "-c"]).first == "/usr/bin/swiftc")
    }
}

extension BuildManifestTests {

    /// Which files a module compiles, so that a run asks only about the modules it changed.
    ///
    /// The sources arrive as a response file in the arguments (`@.../sources`), which names
    /// a file rather than the files. The command's inputs hold the real list.
    @Test("says which files each module compiles")
    func saysWhichFilesEachModuleCompiles() throws {
        let manifest = try #require(BuildManifest(parsing: Self.manifest))
        let core = try #require(manifest.modules.first { $0.name == "Core" })
        #expect(core.sources == ["/pkg/Sources/Core/A.swift"])
    }

    /// Inputs also carry `.swiftmodule` dependencies and stamp files, which are not sources.
    @Test("counts only Swift files as sources")
    func countsOnlySwiftFiles() throws {
        let text = Self.manifest.replacingOccurrences(
            of: #"inputs: ["/pkg/Sources/Core/A.swift"]"#,
            with:
                #"inputs: ["/pkg/Sources/Core/A.swift","/pkg/.build/debug/Modules/Dep.swiftmodule","/pkg/.build/debug/Core.build/sources"]"#
        )
        let manifest = try #require(BuildManifest(parsing: text))
        let core = try #require(manifest.modules.first { $0.name == "Core" })
        #expect(core.sources == ["/pkg/Sources/Core/A.swift"])
    }

    /// A module name may hold hyphens of its own, and the triple that follows it always
    /// holds exactly four. Cutting at the first hyphen would call `swift-syntax` "swift".
    @Test("keeps a hyphenated module's whole name")
    func keepsHyphenatedNames() throws {
        let text = Self.manifest.replacingOccurrences(
            of: "C.Core-arm64-apple-macosx-debug.module",
            with: "C.swift-syntax-arm64-apple-macosx-debug.module"
        )
        let manifest = try #require(BuildManifest(parsing: text))
        #expect(manifest.modules.map(\.name).sorted() == ["App", "swift-syntax"])
    }
}
