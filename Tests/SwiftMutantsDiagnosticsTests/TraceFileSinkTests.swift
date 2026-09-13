// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsTrace
import Testing

@testable import SwiftMutantsDiagnostics

/// Where a recording goes when `--trace` asks for one.
@Suite("Trace file sink")
struct TraceFileSinkTests {

    static func scratch() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-sink-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("writes one line per event, in order")
    func writesOneLinePerEvent() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "trace.jsonl")

        let sink = try TraceFileSink(at: path)
        let recorder = TraceRecorder(retaining: 8, sinks: [sink])
        recorder.record(.phaseBegan(phase: "snapshot"))
        recorder.record(.phaseEnded(phase: "snapshot", durationMilliseconds: 12))
        recorder.record(.runEnded(outcome: "completed"))
        try sink.close()

        let lines = try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        let decoded = try lines.map {
            try JSONDecoder().decode(TraceEvent.self, from: Data($0.utf8))
        }
        #expect(decoded.map(\.sequence) == [1, 2, 3])
    }

    /// Workers record concurrently. A line that arrived interleaved with another would make
    /// the whole recording unreadable from that point on, so the sink serialises writes.
    @Test("never interleaves two lines, however many workers are recording")
    func linesAreWholeUnderConcurrency() async throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "trace.jsonl")

        let sink = try TraceFileSink(at: path)
        let recorder = TraceRecorder(retaining: 0, sinks: [sink])
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<500 {
                group.addTask { recorder.record(.phaseBegan(phase: "phase-\(index)")) }
            }
        }
        try sink.close()

        let lines = try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 500)
        for line in lines {
            #expect(throws: Never.self) {
                try JSONDecoder().decode(TraceEvent.self, from: Data(line.utf8))
            }
        }
    }

    /// A trace is never evidence, so a recording that cannot be written costs a note and
    /// not the run.
    @Test("a sink that cannot write leaves a note and does not stop the run")
    func failureIsANoteNotAnError() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "trace.jsonl")

        let sink = try TraceFileSink(at: path)
        let recorder = TraceRecorder(retaining: 8, sinks: [sink])
        recorder.record(.phaseBegan(phase: "before"))
        try sink.close()

        // Writing to a closed sink is the shape a full disk takes.
        recorder.record(.phaseBegan(phase: "after"))
        #expect(recorder.totalRecorded() == 2)
        #expect(!recorder.sinkFailures().isEmpty)
    }

    @Test("refuses a path it cannot open, rather than silently recording nowhere")
    func refusesAnUnopenablePath() {
        #expect(throws: (any Error).self) {
            try TraceFileSink(at: URL(filePath: "/definitely/not/a/directory/trace.jsonl"))
        }
    }
}
