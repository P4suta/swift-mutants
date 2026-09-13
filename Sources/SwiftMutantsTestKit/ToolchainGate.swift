// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Asks the real toolchain a question, for the gates that have no other way to know.
///
/// This is the one place in the tree that starts a process with `Foundation.Process`.
/// The engine may not: it routes every spawn through `Runner`, which is built on
/// swift-subprocess and is the single point at which a subprocess is recorded. A gate
/// that asks `swiftc` what features it supports is not part of that story - it runs
/// before there is an engine, and what it learns goes into a test assertion rather than
/// into a verdict.
public enum ToolchainGate {

    /// Runs a tool on `PATH` and returns its standard output.
    ///
    /// Output is drained before the child is reaped. The other order deadlocks as soon as
    /// a child writes more than a pipe buffer holds, which is the failure that makes
    /// `Foundation.Process` a poor foundation for the engine itself.
    public static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [tool] + arguments

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        let produced = output.fileHandleForReading.readDataToEndOfFile()
        let complained = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure(
                """
                \(([tool] + arguments).joined(separator: " ")) exited \(process.terminationStatus)
                \(String(decoding: complained, as: UTF8.self))
                """
            )
        }
        return String(decoding: produced, as: UTF8.self)
    }

    /// A toolchain question that could not be answered.
    ///
    /// It carries the command and whatever the tool complained about, because a gate
    /// that fails without saying which invocation failed is a gate somebody has to
    /// reproduce by hand.
    public struct Failure: Error, CustomStringConvertible {
        /// The invocation and the tool's own words.
        public let description: String

        /// Creates a failure from an already-rendered description.
        public init(_ description: String) { self.description = description }
    }
}
