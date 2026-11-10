// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import SwiftMutantsSnapshot
import Testing

@testable import SwiftMutants

@Suite("Exact source decoding")
struct SourceTextTests {
    @Test(
        "source decoding preserves byte order marks, Unicode, and line breaks",
        arguments: [false, true], ["\n", "\r", "\r\n"])
    func preservesBytes(byteOrderMark: Bool, ending: String) throws {
        let fixture = try TestInvocationFixture()
        defer { try? fixture.clean() }
        let source =
            (byteOrderMark ? "\u{FEFF}" : "")
            + "// \u{1F600} e\u{301}\(ending)let enabled = false\(ending)"
        let bytes = Data(source.utf8)
        let path = try #require(WorkspaceRelativePath("Subject.swift"))
        try bytes.write(to: fixture.session.snapshot.root.appending(path: path.rendered))
        let decoded = try fixture.session.readSourceText(path)
        #expect(decoded.utf8.elementsEqual(bytes))
    }

    @Test(
        "malformed UTF-8 source retains its discovery error",
        arguments: [[0xFF], [0xC0, 0x80], [0xED, 0xA0, 0x80]] as [[UInt8]])
    func invalidBytes(bytes: [UInt8]) throws {
        let fixture = try TestInvocationFixture()
        defer { try? fixture.clean() }
        let path = try #require(WorkspaceRelativePath("Subject.swift"))
        try Data(bytes).write(to: fixture.session.snapshot.root.appending(path: path.rendered))
        do {
            _ = try fixture.session.readSourceText(path)
            Issue.record("Malformed UTF-8 source was accepted")
        } catch let failure as MutationTestingError {
            #expect(failure.stage == .discovery)
            #expect(failure.diagnostic.contains(path.rendered))
        }
    }
}
