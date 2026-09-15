// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

extension BuildManifest {

    /// Reads the same plan out of a build that narrates itself.
    ///
    /// SwiftPM's build system stopped writing `debug.yaml`, and nothing announced it: the
    /// file is simply absent, ``init(parsing:)`` reads nothing, and the caller falls back
    /// to building the whole package every round. Correct, silent, and exactly what the
    /// per-module driver exists to avoid.
    ///
    /// What it does write is the same command from a different mouth. A verbose build
    /// prints, for every module, the `builtin-SwiftDriver -- <swiftc> ...` line holding the
    /// invocation it is about to run - the same forty-odd arguments, worked out by the same
    /// planner, and still read rather than guessed at.
    ///
    /// `readingFileList` resolves a `@response-file` to its contents. Injected rather than
    /// read here so that this stays a function from text to a plan: the sources are what
    /// decides which modules a set of instrumented paths touches, and getting them wrong
    /// sends the whole question to a real build.
    ///
    /// Refused rather than empty when no module is named, for the reason ``init(parsing:)``
    /// is: a plan with nothing in it and a plan nobody could read look the same to a caller
    /// and mean opposite things.
    public init?(
        parsingVerboseBuild narration: String,
        readingFileList: (String) -> String?
    ) {
        var found: [Module] = []
        for line in narration.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let marker = line.firstRange(of: Self.driverMarker) else { continue }
            let arguments = Self.words(of: line[marker.upperBound...])
            guard let name = Self.value(after: "-module-name", in: arguments) else { continue }
            found.append(
                Module(
                    name: name,
                    arguments: arguments,
                    sources: Self.sources(of: arguments, readingFileList: readingFileList)
                )
            )
        }
        guard !found.isEmpty else { return nil }
        self.modules = found
    }

    /// What introduces the compiler invocation in a narrated build.
    private static let driverMarker = "builtin-SwiftDriver -- "

    /// The word after `flag`, if the arguments hold one.
    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let at = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: at)
        return next < arguments.endIndex ? arguments[next] : nil
    }

    /// The Swift files a command compiles: named outright, or named by a response file.
    private static func sources(
        of arguments: [String], readingFileList: (String) -> String?
    ) -> [String] {
        var found = arguments.filter { $0.hasSuffix(".swift") && !$0.hasPrefix("-") }
        for argument in arguments where argument.hasPrefix("@") {
            guard let listed = readingFileList(String(argument.dropFirst())) else { continue }
            found += listed.split(separator: "\n").map(String.init)
                .filter { $0.hasSuffix(".swift") }
        }
        return found
    }

    /// Splits a narrated command into the words a shell would hand the compiler.
    ///
    /// The build system escapes rather than quotes: `-D_X\=1`, and a plugin path written as
    /// `plugins/testing\#/usr/bin/swift-plugin-server`. A splitter that broke on spaces
    /// alone would hand the compiler a backslash it cannot read, and the error that
    /// produces is about neither the package nor any mutant in it.
    ///
    /// Quotes are honoured too. Nothing observed here uses them, and a path with a space in
    /// it is not a thing to find out about from a user's bug report.
    private static func words(of text: Substring) -> [String] {
        var found: [String] = []
        var word = ""
        var open: Character?
        var escaped = false
        for character in text {
            if escaped {
                word.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let quote = open {
                if character == quote { open = nil } else { word.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                open = character
                continue
            }
            if character == " " || character == "\t" {
                if !word.isEmpty { found.append(word) }
                word = ""
                continue
            }
            word.append(character)
        }
        if !word.isEmpty { found.append(word) }
        return found
    }
}

extension BuildManifest {

    /// The plan SwiftPM made, from wherever this toolchain leaves it.
    ///
    /// Two places, because there have been two. SwiftPM wrote the plan to `debug.yaml`
    /// beside the build; its replacement does not write it at all and prints the same
    /// commands during a verbose build instead. Nothing announced the change - the file is
    /// simply absent, and a caller that knew only the first place would quietly fall back
    /// to building the whole package every round, which is correct and slow and looks
    /// exactly like working.
    ///
    /// The file first, because a toolchain that writes it has already done the work; then
    /// the narration; then nothing, which is a real answer rather than a failure. A caller
    /// with no plan builds the whole package, which always works.
    public init?(ofBuild narration: String, plannedBeside scratch: String) {
        let beside = scratch + "/debug.yaml"
        if let text = try? String(contentsOfFile: beside, encoding: .utf8),
            let planned = BuildManifest(parsing: text)
        {
            self = planned
            return
        }
        let narrated = BuildManifest(parsingVerboseBuild: narration) {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }
        guard let narrated else { return nil }
        self = narrated
    }
}
