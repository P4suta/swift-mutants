// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsDiagnostics
import SwiftMutantsTrace

/// What a failed run leaves behind.
///
/// A run that fails an hour in has told somebody one line about why, and that line is almost
/// never enough: the question is what it was doing, what it ran, what each thing it ran
/// exited with, and whether the machine is even set up for it. All of that existed while the
/// run was alive and is gone the moment it is not.
///
/// The recording was already being kept - every subprocess passes through one place that
/// writes it down - and nothing was reading it back out. This is the part that does.
enum FailureReport {

    /// How many bundles to keep. Enough to compare a failure with the run before it.
    static let retained = 10

    /// Where bundles live for a package.
    static func home(for package: URL) -> URL {
        let root =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = DigestBuilder()
            .adding("swift-mutants-package")
            .adding(package.standardizedFileURL.path)
            .finalize()
        return
            root
            .appending(path: "swift-mutants")
            .appending(path: "diagnostics-\(name.hexadecimal)")
    }

    /// Writes everything known about a failure, and says where it went.
    ///
    /// Nothing rather than an error when it cannot be written: replacing the failure
    /// somebody was told about with a failure about writing a bundle would lose the only
    /// thing they came for.
    @discardableResult
    static func write(
        _ failure: String,
        recorder: TraceRecorder,
        environment: [String: String],
        keptAt: URL?,
        into home: URL
    ) -> URL? {
        let directory = home.appending(path: "run-\(UUID().uuidString)")
        let contents = DiagnosticsBundle.Contents(
            error: failure,
            errorChain: [failure],
            // Names only. A bundle is something people attach to a bug report, and a value
            // that reached this run would otherwise reach the report.
            environmentNames: Array(environment.keys),
            doctor: nil,
            trace: recorder.retainedEvents(),
            report: nil,
            preservedPaths: keptAt.map { [$0.path] } ?? []
        )
        guard (try? DiagnosticsBundle.write(contents, to: directory)) != nil else { return nil }
        try? DiagnosticsBundle.retain(newest: Self.retained, in: home)
        return directory
    }
}
