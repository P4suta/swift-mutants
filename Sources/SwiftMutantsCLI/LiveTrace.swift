// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftMutantsConsole
import SwiftMutantsTrace

/// The account of what a run started, printed as it happens.
///
/// The same events `--trace` writes to a file, sent through the console the run is already
/// using. That is what `-vv` buys over `--trace`: somebody watching a run that is about to
/// go wrong sees what it ran without having had to ask for a trace directory beforehand -
/// and nobody turns on tracing before the run that fails.
///
/// A sink rather than a branch inside the recorder, because the recording is unconditional
/// and this is only a second reader of it. A run told to be quiet still records everything;
/// it just says none of it.
struct LiveTrace: TraceSink {

    private let renderer: ConsoleRenderer
    private let say: @Sendable (String) -> Void

    /// Prints the account at `verbosity`, if that level asked for it.
    init(verbosity: Verbosity, say: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.renderer = ConsoleRenderer(verbosity: verbosity)
        self.say = say
    }

    /// Prints one event, or passes over it.
    ///
    /// Never throws. A sink that could fail would make the recording a thing a run has to
    /// handle, and the recording is not evidence: nothing about a verdict, an identity or a
    /// cache key passes through here.
    func record(_ event: TraceEvent) throws {
        if let line = renderer.trace(event) { say(line) }
    }
}
