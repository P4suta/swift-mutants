// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsValidate

/// A driver that records what it was asked and answers from a script.
struct Scripted: TypecheckDriver {

    let answer: CompilerOutput
    let asked: Asked

    func typecheck(_ paths: [String]) async -> CompilerOutput {
        asked.record(paths)
        return answer
    }
}

/// What a scripted driver was asked, across however many tasks did the asking.
final class Asked: @unchecked Sendable {

    private let lock = NSLock()
    private var paths: [[String]] = []

    var calls: [[String]] { lock.withLock { paths } }

    func record(_ one: [String]) { lock.withLock { paths.append(one) } }
}

/// Asking each module on its own, all at once.
///
/// `swift build` cannot report an error in a module whose dependency failed to build -
/// there is nothing to build it against - so a package twenty module layers deep needs
/// twenty builds to surface twenty rejections, each of them a build of the whole package.
/// Dogfooding this package took nineteen.
///
/// Asked per module against the modules a pristine build already produced, every module
/// answers at once and answers independently: a broken dependency silences nothing, because
/// nothing is reading the dependency's source. That turns a number of builds proportional
/// to the depth of somebody's package into one pass over its breadth.
@Suite("Asking each module")
struct ModuleDriverTests {

    static func manifest(modules: [(String, [String])]) -> BuildManifest {
        BuildManifest(
            modules: modules.map {
                BuildManifest.Module(
                    name: $0.0, arguments: ["/usr/bin/swiftc", "-c"], sources: $0.1)
            })
    }

    static func driver(_ manifest: BuildManifest, fallback: Scripted) -> ModuleTypecheckDriver {
        ModuleTypecheckDriver(
            runner: Runner(recorder: TraceRecorder()),
            manifest: manifest,
            root: "/pkg",
            environment: [:],
            timeout: .seconds(60),
            fallback: fallback
        )
    }

    /// The safety property. A file this tool instrumented that belongs to no module in the
    /// plan means the plan is not describing the tree - and answering from a plan that does
    /// not describe the tree is how a run rejects mutants at positions nobody reported. So
    /// it stops being clever and builds the package.
    @Test("builds the whole package when a file belongs to no module it knows")
    func fallsBackForAnUnknownFile() async {
        let fallback = Scripted(
            answer: CompilerOutput(exitCode: 0, text: ""), asked: Asked())
        let manifest = Self.manifest(modules: [("Core", ["/pkg/Sources/Core/A.swift"])])

        _ = await Self.driver(manifest, fallback: fallback)
            .typecheck(["/pkg/Sources/Elsewhere/B.swift"])

        #expect(fallback.asked.calls == [["/pkg/Sources/Elsewhere/B.swift"]])
    }

    /// The premise of the test above: a file it does know does not reach the fallback.
    @Test("does not build the whole package for a file it knows")
    func knownFilesDoNotFallBack() async {
        let fallback = Scripted(
            answer: CompilerOutput(exitCode: 0, text: ""), asked: Asked())
        let manifest = Self.manifest(modules: [("Core", ["/pkg/Sources/Core/A.swift"])])

        _ = await Self.driver(manifest, fallback: fallback)
            .typecheck(["/pkg/Sources/Core/A.swift"])

        #expect(fallback.asked.calls.isEmpty)
    }

    /// A tree reached through a symlink is the same tree. macOS hands out more than one
    /// spelling for a path as a matter of course - `/var` and `/private/var` name the same
    /// directory - and SwiftPM's plan and this tool's own paths do not have to agree on
    /// which. Comparing the strings alone once made every diagnostic in a run belong to no
    /// file at all, and the run then explained nothing about anything.
    @Test("knows a file by the tree it is in, not by the spelling of the path")
    func matchesThroughASymlink() async throws {
        let fallback = Scripted(
            answer: CompilerOutput(exitCode: 0, text: ""), asked: Asked())
        let base = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-module-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let real = base.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("let a = 1".utf8).write(to: real.appending(path: "A.swift"))
        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // The plan names the file one way; the run names it the other.
        let manifest = Self.manifest(modules: [("Core", [link.appending(path: "A.swift").path])])
        _ = await Self.driver(manifest, fallback: fallback)
            .typecheck([real.appending(path: "A.swift").path])

        #expect(fallback.asked.calls.isEmpty, "the same file was taken for two")
    }

    /// The premise: the two spellings really are different strings.
    @Test("had two spellings to reconcile")
    func hadTwoSpellings() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-module-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("let a = 1".utf8).write(to: real.appending(path: "A.swift"))
        try FileManager.default.createSymbolicLink(
            at: base.appending(path: "link"), withDestinationURL: real)

        let through = base.appending(path: "link").appending(path: "A.swift").path
        #expect(through != real.appending(path: "A.swift").path)
    }

    @Test("says nothing is wrong when nothing was changed")
    func nothingToAsk() async {
        let fallback = Scripted(
            answer: CompilerOutput(exitCode: 1, text: "should not be reached"),
            asked: Asked())
        let manifest = Self.manifest(modules: [("Core", ["/pkg/Sources/Core/A.swift"])])

        let output = await Self.driver(manifest, fallback: fallback).typecheck([])

        #expect(output.exitCode == 0)
        #expect(fallback.asked.calls.isEmpty)
    }

    /// Only the modules that changed. The rest of a package compiled a moment ago and no
    /// mutant in another module can have changed that: a mutant is an expression, and the
    /// private guard around it is not part of any module's interface.
    @Test("asks only about the modules whose files changed")
    func asksOnlyAboutWhatChanged() {
        let manifest = Self.manifest(modules: [
            ("Core", ["/pkg/Sources/Core/A.swift"]),
            ("App", ["/pkg/Sources/App/B.swift"]),
            ("Untouched", ["/pkg/Sources/Untouched/C.swift"]),
        ])
        let wanted = ModuleTypecheckDriver.modules(
            of: manifest, holding: ["/pkg/Sources/Core/A.swift", "/pkg/Sources/App/B.swift"])
        #expect(wanted?.map(\.name) == ["Core", "App"])
    }

    @Test("finds no module for a file that is in none of them")
    func noModuleForAStranger() {
        let manifest = Self.manifest(modules: [("Core", ["/pkg/Sources/Core/A.swift"])])
        #expect(ModuleTypecheckDriver.modules(of: manifest, holding: ["/pkg/x.swift"]) == nil)
    }
}

/// Putting several modules' answers together into one.
@Suite("Merging what the modules said")
struct MergedOutputTests {

    @Test("accepts the tree only when every module accepted it")
    func acceptsOnlyWhenAllDo() {
        #expect(
            ModuleTypecheckDriver.merged([
                CompilerOutput(exitCode: 0, text: "a"), CompilerOutput(exitCode: 0, text: "b"),
            ]).exitCode == 0
        )
        #expect(
            ModuleTypecheckDriver.merged([
                CompilerOutput(exitCode: 0, text: "a"), CompilerOutput(exitCode: 1, text: "b"),
            ]).exitCode != 0
        )
    }

    /// Every module's diagnostics, not the first module's. Keeping one would put the tool
    /// straight back to one round per module layer, which is the thing this replaces.
    @Test("keeps what every module said")
    func keepsEverySaying() {
        let merged = ModuleTypecheckDriver.merged([
            CompilerOutput(exitCode: 1, text: "Core.swift:1:1: error: no"),
            CompilerOutput(exitCode: 1, text: "App.swift:2:2: error: also no"),
        ])
        #expect(merged.text.contains("Core.swift:1:1: error: no"))
        #expect(merged.text.contains("App.swift:2:2: error: also no"))
    }

    /// Nothing asked is not the same as nothing wrong, but it is the same answer: a tree
    /// nobody changed is a tree the last compile already accepted.
    @Test("accepts a tree it was asked nothing about")
    func acceptsAnEmptyAsking() {
        #expect(ModuleTypecheckDriver.merged([]).exitCode == 0)
    }
}
