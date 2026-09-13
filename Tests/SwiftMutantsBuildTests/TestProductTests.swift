// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import SwiftMutantsBuild

/// Finding what SwiftPM just built, and refusing to guess.
///
/// The shape of a built test product is a fact about what the toolchain produced, not
/// about the machine this is running on: on macOS it is a bundle directory holding a
/// Mach-O that cannot be executed, and elsewhere it is an executable. Asking the
/// filesystem rather than the host is what keeps a cross-build from being read wrong.
@Suite("Test products")
struct TestProductTests {

    struct Scratch {
        let directory: URL
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    static func scratch(_ build: (URL) throws -> Void) throws -> Scratch {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-mutants-product-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try build(directory)
        return Scratch(directory: directory)
    }

    static func bundle(_ name: String, in directory: URL) throws {
        let stem = String(name.dropLast(".xctest".count))
        let binary = directory.appending(path: "\(name)/Contents/MacOS/\(stem)")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
    }

    @Test("finds the binary inside a bundle")
    func bundleProduct() throws {
        let scratch = try Self.scratch { try Self.bundle("PkgTests.xctest", in: $0) }
        defer { scratch.cleanUp() }

        let product = try SwiftPackageManager.testProduct(in: scratch.directory)
        #expect(product.isBundle)
        #expect(product.executable.lastPathComponent == "PkgTests")
        #expect(product.executable.path.hasSuffix("PkgTests.xctest/Contents/MacOS/PkgTests"))
    }

    @Test("takes an executable product as it is")
    func executableProduct() throws {
        let scratch = try Self.scratch {
            try Data().write(to: $0.appending(path: "PkgTests.xctest"))
        }
        defer { scratch.cleanUp() }

        let product = try SwiftPackageManager.testProduct(in: scratch.directory)
        #expect(!product.isBundle)
        #expect(product.executable.lastPathComponent == "PkgTests.xctest")
    }

    /// Picking one would be picking for somebody, and the one not picked would be a whole
    /// test target whose mutants were reported as surviving.
    @Test("refuses to choose between two test bundles")
    func severalBundles() throws {
        let scratch = try Self.scratch {
            try Self.bundle("OneTests.xctest", in: $0)
            try Self.bundle("TwoTests.xctest", in: $0)
        }
        defer { scratch.cleanUp() }

        let failure = #expect(throws: BuildSystemError.self) {
            try SwiftPackageManager.testProduct(in: scratch.directory)
        }
        #expect(failure?.description.contains("OneTests.xctest, TwoTests.xctest") == true)
    }

    /// A package that built but has no tests has nothing for a mutant to be caught by,
    /// and every mutant would be reported as surviving.
    @Test("says when there is no test bundle at all")
    func noBundle() throws {
        let scratch = try Self.scratch { try Data().write(to: $0.appending(path: "Pkg")) }
        defer { scratch.cleanUp() }

        let failure = #expect(throws: BuildSystemError.self) {
            try SwiftPackageManager.testProduct(in: scratch.directory)
        }
        #expect(failure?.description.contains("no test bundle") == true)
    }

    @Test("says when the build directory is not there")
    func noDirectory() {
        #expect(throws: BuildSystemError.self) {
            try SwiftPackageManager.testProduct(in: URL(filePath: "/no/such/bin/path"))
        }
    }
}
