// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

struct PackageFixture {
    let root: URL

    init(tests: String, source: String = Self.source, extraTarget: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "swift-mutants-measurement-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(
            "Package.swift",
            """
            // swift-tools-version: 6.3
            import PackageDescription
            let package = Package(name: "Subject", platforms: [.macOS(.v15)], targets: [
                .target(name: "Subject"),
                .testTarget(name: "SubjectTests", dependencies: ["Subject"]),
                \(extraTarget ? ".testTarget(name: \"AdditionalTests\", dependencies: [\"Subject\"])," : "")
            ])
            """
        )
        try write("Sources/Subject/Subject.swift", source)
        try write("Tests/SubjectTests/SubjectTests.swift", tests)
        if extraTarget {
            try write(
                "Tests/AdditionalTests/AdditionalTests.swift",
                """
                import Testing
                import Subject
                @Test func additional() { #expect(Subject.add(2, 3) == 5) }
                """
            )
        }
    }

    static let source = """
        public enum Subject {
            public static func add(_ a: Int, _ b: Int) -> Int { a + b }
            public static func scale(_ a: Int, _ b: Int) -> Int { a * b }
        }
        """

    static let testing = """
        import Testing
        import Subject
        @Test func adds() { #expect(Subject.add(2, 3) == 5) }
        """

    static let xctest = """
        import XCTest
        import Subject
        final class AdditionTests: XCTestCase {
            func testAdds() { XCTAssertEqual(Subject.add(2, 3), 5) }
        }
        """

    func write(_ path: String, _ text: String) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func remove() throws { try FileManager.default.removeItem(at: root) }
}
