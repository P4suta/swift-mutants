// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsRunner
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsValidate

/// How many compilers this may have running at once.
///
/// Asking every module on its own is what turned a compile per module layer into one pass
/// over a package's breadth, and that is the right shape. What it left open is how wide the
/// pass may be: every module was started at once, so a package of fifty modules started
/// fifty compilers.
///
/// A compiler is the most memory-hungry thing this tool starts - far more so than a test
/// process, which is what `--jobs` was written for - and fifty of them on one machine is
/// not parallelism, it is a machine that swaps. The failure is in the direction that hurts
/// most: a run that was supposed to be fast becomes a run that is slower than the serial
/// one it replaced, and nothing in the output says why.
///
/// So `jobs` bounds every process this tool starts, whatever kind it is. One number, which
/// is also the one a user already knows how to turn down.
@Suite("How wide the module pass may be")
struct ModuleFanOutTests {

    /// A script that records how many copies of itself were running when it started.
    ///
    /// Asked of the processes themselves rather than of the driver, because a driver that
    /// miscounted its own compilers would agree with itself.
    static func recorder(in directory: URL) throws -> URL {
        let script = directory.appending(path: "compiler.sh")
        try """
        #!/bin/sh
        mine="\(directory.path)/live.$$"
        : > "$mine"
        # shellcheck disable=SC2012
        ls "\(directory.path)"/live.* | wc -l >> "\(directory.path)/inflight.txt"
        sleep 0.2
        rm -f "$mine"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    static func widest(in directory: URL) throws -> Int {
        let text = try String(
            contentsOf: directory.appending(path: "inflight.txt"), encoding: .utf8)
        return text.split(separator: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .max() ?? 0
    }

    @Test("starts no more compilers at once than it was allowed")
    func boundedByJobs() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "swift-mutants-fan-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let compiler = try Self.recorder(in: scratch)

        let modules = (0..<12).map { position in
            BuildManifest.Module(
                name: "M\(position)",
                arguments: [compiler.path, "-c"],
                sources: ["/pkg/Sources/M\(position)/A.swift"]
            )
        }
        let driver = ModuleTypecheckDriver(
            runner: Runner(recorder: TraceRecorder()),
            manifest: BuildManifest(modules: modules),
            root: scratch.path,
            environment: [:],
            timeout: .seconds(60),
            jobs: 3,
            fallback: Scripted(answer: CompilerOutput(exitCode: 0, text: ""), asked: Asked())
        )

        let said = await driver.typecheck(modules.map { $0.sources[0] })
        #expect(said.exitCode == 0)

        let widest = try Self.widest(in: scratch)
        #expect(widest > 0, "no compiler recorded itself, so nothing was measured")
        #expect(widest <= 3, "started \(widest) compilers at once")
    }

    /// Every module still gets asked. A ceiling that answered about fewer modules than it
    /// was given would be a ceiling that accepted a tree nobody type-checked, which is the
    /// one mistake this phase cannot make.
    @Test("still asks every module it was given")
    func asksEveryone() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "swift-mutants-fan-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let compiler = try Self.recorder(in: scratch)

        let modules = (0..<7).map { position in
            BuildManifest.Module(
                name: "M\(position)",
                arguments: [compiler.path],
                sources: ["/pkg/Sources/M\(position)/A.swift"]
            )
        }
        let driver = ModuleTypecheckDriver(
            runner: Runner(recorder: TraceRecorder()),
            manifest: BuildManifest(modules: modules),
            root: scratch.path,
            environment: [:],
            timeout: .seconds(60),
            jobs: 2,
            fallback: Scripted(answer: CompilerOutput(exitCode: 0, text: ""), asked: Asked())
        )
        _ = await driver.typecheck(modules.map { $0.sources[0] })

        let started = try String(
            contentsOf: scratch.appending(path: "inflight.txt"), encoding: .utf8
        ).split(separator: "\n").count
        #expect(started == modules.count, "\(started) of \(modules.count) modules were asked")
    }
}
